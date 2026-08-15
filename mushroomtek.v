module main

import os
import time
import rand
import rand.seed
import term
import strconv

#include <poll.h>
#include <unistd.h>

struct C.pollfd {
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u32, timeout int) int
fn C.read(fd int, buf voidptr, count usize) isize

const band_lock_mask = 'AT+EPBSE=154,155,4,0,0,0,0,0,0,0'
const save_path = './hopper.list'
const log_path = './hopper.log'
const blacklist_path = './hopper.blacklist'
const history_path = './hopper.history'
const backup_path = './hopper.backup'

const wlan_cfg_path = '/proc/net/wlan/cfg'
const wlan_bak_path = './wlancfg'

struct CellState {
mut:
	lac          string
	cid          string
	rat          int
	plmn         string
	rssi         int
	api_verified bool = true
}

struct TrustReport {
	score   int
	reasons []string
}

struct WlanSetting {
	key string
	val string
}

struct AsyncVerifyArgs {
	plmn        string
	lac         string
	cid         string
	rat         int
	socks_proxy string
}

fn hex_to_dec(hex_str string) string {
	clean := hex_str.replace('"', '').trim_space().replace('0x', '').replace('0X', '')
	if clean.len == 0 {
		return '0'
	}
	val := strconv.parse_uint(clean, 16, 64) or { 0 }
	return val.str()
}

fn get_secure_seed() []u32 {
	mut seed_bytes := []u8{len: 8}
	mut f := os.open('/dev/urandom') or {
		return seed.time_seed_array(2)
	}
	f.read(mut seed_bytes) or {}
	f.close()
	
	mut seed_array := []u32{len: 2}
	seed_array[0] = (u32(seed_bytes[0]) << 24) | (u32(seed_bytes[1]) << 16) | (u32(seed_bytes[2]) << 8) | u32(seed_bytes[3])
	seed_array[1] = (u32(seed_bytes[4]) << 24) | (u32(seed_bytes[5]) << 16) | (u32(seed_bytes[6]) << 8) | u32(seed_bytes[7])
	return seed_array
}

fn apply_random_ta_spoof(path string) {
	rand_ta_offset := rand.int_in_range(5, 60) or { 10 }
	log_event('TA_SPOOF: Injecting volatile timing offset of ${rand_ta_offset}us')
	send(path, 'AT+ERFTX=0,${rand_ta_offset}') // check com/mediatek/engineermode/modemtest/ModemTestActivity to get more details :-}
}

fn restore_system_state(active_modems []string, band_default string, rat_default string) {
	println(term.bold('\n[!] Initiating system teardown. Restoring all parameters to Day One state...'))
	
	// if os.exists(wlan_bak_path) {
	//	println('[*] Restoring Wi-Fi anti-tracking configuration...')
	//	lines := os.read_lines(wlan_bak_path) or { []string{} }
	//	for line in lines {
	//		l := line.trim_space()
	//		if l.len > 0 {
	//			write_wlan_cfg(l)
    //		}
	//	}
	//	println(term.green('[+] Wi-Fi settings successfully restored.'))
	//}

	println('[*] Releasing cell locks and restoring default carrier configurations...')
	for m in active_modems {
		send(m, 'AT+EMMCHLCK=0')
		send(m, band_default)
		send(m, rat_default)
	}
	
	println(term.green('[+] Modem released from locked state. Cellular connection naturally re-establishing.'))
	log_event('EXIT_AND_RESTORED_SUCCESSFULLY')
}

fn async_verify_cell_tower(args AsyncVerifyArgs) {
	if args.plmn.len < 5 || args.lac.len == 0 || args.cid.len == 0 {
		return
	}
	mcc := args.plmn[0..3]
	mnc := args.plmn[3..]

	lac_dec := hex_to_dec(args.lac)
	cid_dec := hex_to_dec(args.cid)

	radio_type := match args.rat {
		0, 1, 3 { 'gsm' }
		2, 4, 5, 6 { 'wcdma' }
		7 { 'lte' }
		else { 'lte' }
	}

	payload := '{"cellTowers": [{"radioType": "${radio_type}", "mobileCountryCode": ${mcc}, "mobileNetworkCode": ${mnc}, "locationAreaCode": ${lac_dec}, "cellId": ${cid_dec}}]}'

	mut cmd := 'curl -s -m 8 -X POST https://api.beacondb.net/v1/geolocate'
	cmd += ' -H "Content-Type: application/json"'
	cmd += ' -H "User-Agent: HopperCellTowerVerifier/1.0"'

	if args.socks_proxy.len > 0 {
		cmd += ' --socks5-hostname ${args.socks_proxy}'
	}

	cmd += " -d '${payload}'"

	res := os.execute(cmd)
	if res.exit_code != 0 {
		log_event('API CHECK ASYNC: Connection error or proxy timeout.')
		return
	}

	resp := res.output.trim_space()
	if resp.len == 0 || !resp.contains('{') {
		return
	}

	if !resp.contains('"location":') {
		msg := 'ALERT: Tower ${args.cid} (LAC: ${args.lac}) NOT FOUND in public databases! Fake Cell Risk!'
		println('\n' + term.red('CRITICAL ALERT | ' + msg))
		log_event('CRITICAL ' + msg)
		alert_sound()
	} else {
		log_event('API CHECK ASYNC: Tower ${args.cid} verified successfully.')
	}
}

fn query_device(path string, cmd string, timeout_ms int) string {
	mut f := os.open_file(path, 'r+') or {
		log_event('ERROR: Failed to open device ${path} for query')
		return ''
	}
	defer {
		f.close()
	}

	mut flush_pfd := C.pollfd{
		fd: f.fd
		events: 1
		revents: 0
	}
	for C.poll(&flush_pfd, 1, 0) > 0 {
		mut junk := [256]u8{}
		unsafe { C.read(f.fd, &junk[0], 256) }
	}

	f.write_string(cmd + '\r\n') or {
		log_event('ERROR: Failed to write command to ${path}')
		return ''
	}

	mut response := ''
	mut pfd := C.pollfd{
		fd: f.fd
		events: 1
		revents: 0
	}

	start := time.now()
	for {
		elapsed := time.since(start).milliseconds()
		remaining := timeout_ms - int(elapsed)
		if remaining <= 0 {
			break
		}

		ret := C.poll(&pfd, 1, remaining)
		if ret <= 0 {
			break
		}

		if (pfd.revents & 1) != 0 {
			mut buf := [1024]u8{}
			n := unsafe { C.read(f.fd, &buf[0], 1024) }
			if n > 0 {
				response += unsafe { buf[0..n].bytestr() }
				if response.contains('OK\r\n') || response.contains('ERROR\r\n') || response.contains('+CME ERROR:') {
					break
				}
			} else {
				break
			}
		} else if (pfd.revents & (8 | 16)) != 0 {
			break
		}
	}

	return response.trim_space()
}

fn send(path string, cmd string) {
    println('${path} :: ${cmd}')
	mut f := os.open_file(path, 'r+') or {
		log_event('ERROR: Failed to open ${path} for send')
		return
	}
	f.write_string(cmd + '\r\n') or {
		log_event('ERROR: Failed to write ${cmd} to ${path}')
	}
	f.close()
}

fn query(path string, cmd string) string {
	return query_device(path, cmd, 2000)
}

fn check_command_support(path string, cmd string) bool {
	mut queries := []string{}
	if cmd in ['CSQ', 'ECELL'] {
		queries << 'AT+' + cmd
	} else {
		queries << 'AT+' + cmd + '?'
		queries << 'AT+' + cmd + '=?'
	}

	for q in queries {
		resp := query_device(path, q, 1000)
		if resp.len > 0 && !resp.contains('ERROR') {
			return true
		}
	}
	return false
}

fn get_default_band(path string) ?string {
	resp := query(path, 'AT+EPBSE?')
	for line in resp.split_into_lines() {
		l := line.trim_space()
		if l.starts_with('+EPBSE:') {
			return 'AT+EPBSE=' + l.all_after(':').trim_space()
		}
	}
	return none
}

fn get_default_rat(path string) ?string {
	resp := query(path, 'AT+ERAT?')
	for line in resp.split_into_lines() {
		l := line.trim_space()
		if l.starts_with('+ERAT:') {
			return 'AT+ERAT=' + l.all_after(':').trim_space()
		}
	}
	return none
}

fn get_cell_state(path string) CellState {
	mut state := CellState{rat: -1, rssi: -1}

	resp_cereg := query_device(path, 'AT+CEREG?', 1000)
	resp_cgreg := query_device(path, 'AT+CGREG?', 1000)
	resp_eops := query_device(path, 'AT+EOPS?', 1000)
	resp_csq := query_device(path, 'AT+CSQ', 1000)

	combined := '${resp_cereg}\n${resp_cgreg}\n${resp_eops}\n${resp_csq}'

	for line in combined.split_into_lines() {
		l := line.trim_space()
		if (l.starts_with('+CGREG:') || l.starts_with('+CEREG:')) && state.lac.len == 0 {
			parts := l.all_after(':').split(',')
			if parts.len >= 5 {
				state.lac = parts[2].replace('"', '').trim_space()
				state.cid = parts[3].replace('"', '').trim_space()
				state.rat = parts[4].trim_space().int()
			}
		}
		if l.starts_with('+EOPS:') || l.starts_with('+COPS:') {
			parts := l.all_after(':').split(',')
			if parts.len >= 3 {
				state.plmn = parts[2].replace('"', '').trim_space()
			}
		}
		if l.starts_with('+CSQ:') {
			parts := l.all_after(':').split(',')
			if parts.len >= 1 {
				state.rssi = parts[0].trim_space().int()
			}
		}
	}
	return state
}

fn count_cells(resp string) int {
	mut count := 0
	for line in resp.split_into_lines() {
		if line.trim_space().starts_with('+ECELL:') {
			count++
		}
	}
	if count <= 1 && resp.contains('+ECELL:') {
		mut q := 0
		for c in resp {
			if c == `"` {
				q++
			}
		}
		alt := q / 4
		if alt > count {
			count = alt
		}
	}
	return count
}

fn get_neighbor_count(path string) int {
	resp := query(path, 'AT+ECELL')
	return count_cells(resp)
}

fn rat_name(rat int) string {
	return match rat {
		0, 1, 3 { 'GSM' }
		2, 4, 5, 6 { '3G' }
		7 { 'LTE' }
		else { rat.str() }
	}
}

fn check_anomalies(prev CellState, curr CellState, modems []string) {
	if prev.lac.len == 0 {
		return
	}
	if curr.lac != prev.lac && curr.lac.len > 0 {
		msg := 'LAC: ' + prev.lac + ' -> ' + curr.lac
		println(term.red('ALERT ' + msg))
		log_event('ALERT ' + msg)
	}
	if curr.cid != prev.cid && curr.cid.len > 0 {
		msg := 'CID: ' + prev.cid + ' -> ' + curr.cid
		println(term.yellow('WARN ' + msg))
		log_event('WARN ' + msg)
	}
	if prev.rat == 7 && curr.rat >= 0 && curr.rat <= 3 {
		msg := 'RAT DOWNGRADE ' + rat_name(prev.rat) + ' -> ' + rat_name(curr.rat)
		println(term.red('ALERT ' + msg))
		log_event('ALERT ' + msg)
		for m in modems {
			send(m, 'AT+ERAT=6')
		}
	}
	if curr.plmn != prev.plmn && curr.plmn.len > 0 && prev.plmn.len > 0 {
		msg := 'PLMN: ' + prev.plmn + ' -> ' + curr.plmn
		println(term.red('ALERT ' + msg))
		log_event('ALERT ' + msg)
	}
	if prev.rssi > 0 && curr.rssi > 0 && curr.rssi != 99 && (curr.rssi - prev.rssi) > 10 {
		msg := 'Signal spike ' + prev.rssi.str() + ' -> ' + curr.rssi.str()
		println(term.red('ALERT ' + msg))
		log_event('ALERT ' + msg)
	}
}

fn check_jamming(prev_count int, curr_count int) {
	if prev_count < 0 {
		return
	}
	if prev_count > 1 {
		msg := 'Possible neighbors: ' + prev_count.str() + ' -> ' + curr_count.str()
		println(term.red('ALERT ' + msg))
		log_event('ALERT ' + msg)
		alert_sound()
	}
}

fn calculate_trust(curr CellState, prev CellState, nbr int) TrustReport {
	mut score := 100
	mut reasons := []string{}

	if !curr.api_verified {
		score -= 50
		reasons << 'Cell Tower not found in public databases (Fake Cell Risk)'
	}
	if nbr > 2 {
		score -= 20
		reasons << 'Neighbors: ' + nbr.str()
	}
	if prev.rat == 7 && curr.rat >= 0 && curr.rat <= 3 {
		score -= 30
		reasons << 'RAT downgrade LTE->GSM'
	} else if prev.rat == 7 && curr.rat >= 2 && curr.rat <= 6 {
		score -= 15
		reasons << 'RAT downgrade LTE->3G'
	}
	if curr.rssi > 0 && curr.rssi != 99 && curr.rssi > 28 {
		score -= 15
		reasons << 'Strong signal: ' + curr.rssi.str()
	}
	if prev.lac.len > 0 && curr.lac != prev.lac && curr.lac.len > 0 {
		score -= 20
		reasons << 'LAC changed'
	}
	if prev.plmn.len > 0 && curr.plmn != prev.plmn && curr.plmn.len > 0 {
		score -= 25
		reasons << 'PLMN changed'
	}
	if score < 0 {
		score = 0
	}
	return TrustReport{
		score: score
		reasons: reasons
	}
}

fn display_trust(report TrustReport) {
	label := if report.score >= 70 {
		term.green('Trust: ' + report.score.str() + '/100')
	} else if report.score >= 40 {
		term.yellow('Trust: ' + report.score.str() + '/100')
	} else {
		term.red('Trust: ' + report.score.str() + '/100')
	}
	println(label)
	for r in report.reasons {
		println(' - ' + r)
	}
	if report.score < 30 {
		log_event('LOW_TRUST ' + report.score.str())
		alert_sound()
	}
}

fn alert_sound() {
	os.system('echo -ne "\a" 2>/dev/null')
}

fn has_input() bool {
	mut pfd := C.pollfd{
		fd: 0
		events: 1
		revents: 0
	}
	return C.poll(&pfd, 1, 0) > 0
}

fn log_event(msg string) {
	mut f := os.open_append(log_path) or { return }
	f.write_string(time.now().format_ss() + ' | ' + msg + '\n') or {}
	f.close()
}

fn save_list(list []string) {
	os.write_file(save_path, list.join('\n')) or {
		log_event('ERROR: Failed to save whitelist to ${save_path}')
	}
}

fn load_list() []string {
	data := os.read_file(save_path) or { return [] }
	mut result := []string{}
	for line in data.split('\n') {
		val := line.trim_space()
		if val.len > 0 {
			result << val
		}
	}
	return result
}

fn load_blacklist() []string {
	data := os.read_file(blacklist_path) or { return [] }
	mut result := []string{}
	for line in data.split('\n') {
		val := line.trim_space()
		if val.len > 0 {
			result << val
		}
	}
	return result
}

fn save_blacklist(list []string) {
	os.write_file(blacklist_path, list.join('\n')) or {
		log_event('ERROR: Failed to save blacklist to ${blacklist_path}')
	}
}

fn record_cell(curr CellState, trust int) {
	mut f := os.open_append(history_path) or { return }
	f.write_string(time.now().format_ss() + '|' + curr.lac + '|' + curr.cid + '|' + curr.rat.str() + '|' + curr.plmn + '|' + curr.rssi.str() + '|' + trust.str() + '\n') or {}
	f.close()
}

fn is_new_cell(cid string) bool {
	data := os.read_file(history_path) or { return true }
	for line in data.split('\n') {
		parts := line.split('|')
		if parts.len >= 3 && parts[2] == cid {
			return false
		}
	}
	return true
}

fn safe_input(prompt string) string {
	res := os.input(prompt)
	if res == '' {
		return ''
	}
	return res.trim_space()
}

fn normalize_wlan_val(raw string) string {
	mut clean := raw.trim_space()
	if clean.starts_with('0x') || clean.starts_with('0X') {
		clean = clean[2..]
		mut val := u64(0)
		for c in clean {
			val = val << 4
			if c >= `0` && c <= `9` {
				val += u64(c - `0`)
			} else if c >= `a` && c <= `f` {
				val += u64(10 + (c - `a`))
			} else if c >= `A` && c <= `F` {
				val += u64(10 + (c - `A`))
			}
		}
		return val.str()
	}
	return clean
}

fn get_wlan_val(key string) ?string {
	lines := os.read_lines(wlan_cfg_path) or { return none }
	for line in lines {
		if line.starts_with(key + '|') || line.starts_with('D:' + key + '|') {
			parts := line.split('|')
			if parts.len == 2 {
				return normalize_wlan_val(parts[1])
			}
		}
	}
	return none
}

fn write_wlan_cfg(cmd string) bool {
	mut f := os.open_file(wlan_cfg_path, 'w') or { return false }
	f.write_string(cmd + '\n') or {
		f.close()
		return false
	}
	f.close()
	return true
}

fn run_wlan(action string) {
	if !os.exists(wlan_cfg_path) {
		println(term.red('[!] Error: Target Wi-Fi interface not found. Operation aborted.'))
		exit(1)
	}

	target_settings := [
		WlanSetting{'CtiaMode', '1'},
		WlanSetting{'Nss', '1'},
		WlanSetting{'StaUapsd', '1'},
		WlanSetting{'StaVHTBfee', '0'},
		WlanSetting{'StaHEBfee', '0'},
		WlanSetting{'TWTRequester', '0'},
		WlanSetting{'P2pGoACSEnable', '0'},
	]

	mut supported := []WlanSetting{}
	mut unsupported := []string{}

	for setting in target_settings {
		if _ := get_wlan_val(setting.key) {
			supported << setting
		} else {
			unsupported << setting.key
		}
	}

	if supported.len == 0 {
		println(term.red('[!] Error: None of the target Wi-Fi parameters are supported by this device.'))
		exit(1)
	}

	if action == 'apply' {
		if unsupported.len > 0 {
			println(term.yellow('[!] Warning: The following parameters are not supported and will be skipped: ' + unsupported.join(', ')))
		}

		if !os.exists(wlan_bak_path) {
			println('[*] Generating configuration backup...')
			mut f := os.create(wlan_bak_path) or {
				println(term.red('[!] Error: Failed to create backup file at ' + wlan_bak_path))
				exit(1)
			}
			for s in supported {
				val := get_wlan_val(s.key) or { continue }
				f.write_string('${s.key} ${val}\n') or {}
			}
			f.close()
			println(term.green('[+] Backup successfully saved to ' + wlan_bak_path))
		} else {
			println(term.yellow('[*] Backup file already exists at ' + wlan_bak_path + '. Skipping overwrite.'))
		}

		println('[*] Applying Wi-Fi anti-tracking profile...')
		mut success_count := 0
		for s in supported {
			if !write_wlan_cfg('${s.key} ${s.val}') {
				println(term.red('[!] Error: Failed to apply ' + s.key))
			} else {
				success_count++
			}
		}
		if success_count > 0 {
			println(term.green('[+] GhostMe mode activated successfully :-]'))
		}
	} else if action == 'restore' {
		if !os.exists(wlan_bak_path) {
			println(term.red('[!] Error: Backup file missing. Cannot restore configuration.'))
			exit(1)
		}
		println('[*] Restoring original configuration...')
		lines := os.read_lines(wlan_bak_path) or {
			println(term.red('[!] Error: Failed to read backup file.'))
			exit(1)
		}
		for line in lines {
			l := line.trim_space()
			if l.len > 0 {
				if !write_wlan_cfg(l) {
					println(term.red('[!] Error: Failed to restore ' + l))
				}
			}
		}
		println(term.green('[+] Wi-Fi profile restored successfully.'))
	} else if action == 'status' {
		println('[*] Current Wi-Fi Parameters:')
		for s in target_settings {
			val := get_wlan_val(s.key) or { 'NOT SUPPORTED' }
			println(s.key + ': ' + val)
		}
	} else {
		println(term.red('[!] Unknown action: ' + action))
		println('Usage: ' + os.args[0] + ' wlan {apply|restore|status}')
		exit(1)
	}
}

fn run_hopper() {
	rand.seed(get_secure_seed())

	mut active_modems := []string{}
	if os.exists('/dev/radio/pttynwcmd') {
		active_modems << '/dev/radio/pttynwcmd'
	} else if os.exists('/dev/radio/atci1') {
		active_modems << '/dev/radio/atci1'
	}

	if os.exists('/dev/radio/atci2') {
		ans := safe_input('Protect atci2(sim2)? (y/n): ')
		if ans == 'y' {
			active_modems << '/dev/radio/atci2'
		}
	}

	if active_modems.len == 0 {
		println(term.red('No radio interfaces found.'))
		exit(1)
	}

	println('Checking required AT command support on modem...')
	required_cmds := ['EMMCHLCK', 'EPBSE', 'ERAT', 'ECELL', 'CEREG', 'CGREG', 'CSQ', 'CFUN']
	mut unsupported := []string{}
	for req in required_cmds {
		if !check_command_support(active_modems[0], req) {
			unsupported << 'AT+' + req
		}
	}
	if !check_command_support(active_modems[0], 'EOPS') && !check_command_support(active_modems[0], 'COPS') {
		unsupported << 'AT+COPS/AT+EOPS'
	}

	if unsupported.len > 0 {
		println(term.red('Error: The following required commands are not supported by this modem: ' + unsupported.join(', ')))
		println(term.red('Error: Modem is not supported.'))
		exit(1)
	}
	println(term.green('Modem verification successful. All required commands are supported.'))

	mut band_default := ''
	mut rat_default := ''

	if os.exists(backup_path) {
		backup_data := os.read_file(backup_path) or {
			println(term.red('Error: Failed to read backup file ' + backup_path))
			exit(1)
		}
		lines := backup_data.split_into_lines()
		if lines.len < 2 {
			println(term.red('Error: Backup file is corrupted or incomplete.'))
			exit(1)
		}
		band_default = lines[0].trim_space()
		rat_default = lines[1].trim_space()
		println(term.green('Loaded default settings from backup file.'))
	} else {
		band_opt := get_default_band(active_modems[0]) or {
			println(term.red('Error: Failed to read default band settings from modem.'))
			exit(1)
		}
		rat_opt := get_default_rat(active_modems[0]) or {
			println(term.red('Error: Failed to read default RAT settings from modem.'))
			exit(1)
		}
		band_default = band_opt
		rat_default = rat_opt

		os.write_file(backup_path, '${band_default}\n${rat_default}') or {
			println(term.red('Error: Failed to create backup file ' + backup_path))
			exit(1)
		}
		println(term.green('Backup of default settings successfully saved.'))
	}

	os.signal_opt(.int, fn [active_modems, band_default, rat_default] (_ os.Signal) {
		restore_system_state(active_modems, band_default, rat_default)
		exit(0)
	}) or {}

	for m in active_modems {
		send(m, 'AT+CEREG=2')
		time.sleep(200 * time.millisecond)
		send(m, 'AT+CGREG=3')
		time.sleep(200 * time.millisecond)
	}
	println('\n' + term.bold('=== Initial Cell Status & Neighbors ==='))
	init_state := get_cell_state(active_modems[0])
	println('Status -> LAC: ' + init_state.lac + ' | CID: ' + init_state.cid +
		' | RAT: ' + rat_name(init_state.rat) + ' | PLMN: ' + init_state.plmn +
		' | RSSI: ' + init_state.rssi.str())

	println('\nNeighbors (AT+ECELL):')
	init_nbr_resp := query(active_modems[0], 'AT+ECELL')
	if init_nbr_resp.len > 0 {
		println(init_nbr_resp)
	} else {
		println('No neighbor response received.')
	}
	println('Count: ' + count_cells(init_nbr_resp).str())
	println(term.bold('=======================================\n'))

	mut api_check_enabled := false
	mut socks_proxy := ''

	is_api_ans := safe_input('Enable Online Cell Database Verification? (y/n): ')
	if is_api_ans == 'y' {
		api_check_enabled = true
		proxy_ans := safe_input('Enter SOCKS5 Proxy if required (e.g. 127.0.0.1:1080) [Press Enter to Skip]: ')
		if proxy_ans.len > 0 {
			socks_proxy = proxy_ans
			println(term.yellow('Using SOCKS5 Proxy: ' + socks_proxy))
		}
	}

	mut manual_cid := '0'
	println(term.yellow('CID locked to 0 by default you can change it with ~CID and if you have connection problems type ~ without CID (be aware channel Lock is 0x0 mode not 0x3 while youre using channelLock without the CID param :-/)')) // because we cannot set channelLock mode to 0x3 without cid so ,,3 is wrong

	mut ta_spoof_enabled := false
	is_ta_ans := safe_input('Enable Random Tx (Timing Advance) Spoofing? (y/n): ')
	if is_ta_ans == 'y' {
		ta_spoof_enabled = true
		println(term.yellow('Random Timing Advance Spoofing enabled.'))
	}

	mut whitelist := load_list()
	if whitelist.len > 0 {
		println('Saved: ' + whitelist.str())
		ans := safe_input('Use saved? (y/n): ')
		if ans != 'y' {
			whitelist = []
		}
	}
	if whitelist.len == 0 {
		earfcns_input := safe_input('EARFCNs: ')
		for rp in earfcns_input.split(',') {
			val := rp.trim_space()
			if val.len > 0 {
				whitelist << val
			}
		}
	}
	if whitelist.len == 0 {
		whitelist << '0'
	}
	save_list(whitelist)

	mut blacklist := load_blacklist()
	mut target_scores := map[string]int{}

	log_event('START ' + whitelist.str())
	println('Commands: pause next list status trust neighbors scan history lte at >EARFCN +EARFCN -EARFCN ~CID ~ !CID !!CID')

	mut manual_target := ''
	mut prev_state := CellState{rat: -1, rssi: -1}
	mut prev_nbr := -1
	mut tick := 0
	mut is_paused := false
	mut oldplmn := ''
	mut oldlac := ''
	mut oldcid := ''

	for {
		mut target := ''
		if manual_target != '' {
			target = manual_target
			manual_target = ''
			println('\n>>> Manual: ' + term.green(target))
		} else {
			if whitelist.len == 0 {
				whitelist << '0'
			}

			target = rand.element(whitelist) or { '0' }
			println('\n>>> Auto: ' + term.green(target))
		}

		for m in active_modems {
			send(m, 'AT+ERAT=3')
			send(m, band_lock_mask)
			if ta_spoof_enabled {
				apply_random_ta_spoof(m)
			}
		}
		time.sleep(500 * time.millisecond)

		// if manual_cid != '' {
		// 	for m in active_modems {
		// 		send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',,0')
        //         send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',,3')
		// 	}
		// 	println('Searching cells (Step 1)...')
		// 	time.sleep(3000 * time.millisecond)
		// }

		for m in active_modems {
            send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',' + manual_cid + ',0')
            send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',' + manual_cid + ',3')
		}
		log_event('LOCK ' + target + ' (CID: ' + manual_cid + ')')

		delay := rand.int_in_range(15, 75) or { 30 }
		println('Hoping dynamic interval: ' + delay.str() + ' seconds')

		mut sw := time.new_stopwatch()
		tick = 0

		for {
			if !is_paused && sw.elapsed().seconds() >= f64(delay) {
				break
			}
			tick++
			if tick >= 25 && !has_input() {
				tick = 0
				mut curr := get_cell_state(active_modems[0])
				if curr.lac.len > 0 {
					check_anomalies(prev_state, curr, active_modems)

					nbr := get_neighbor_count(active_modems[0])
					check_jamming(prev_nbr, nbr)
					prev_nbr = nbr

					if api_check_enabled && curr.plmn.len >= 5 && (curr.plmn != oldplmn || curr.lac != oldlac || curr.cid != oldcid) {
						println('Verifying tower ${curr.cid} (LAC: ${curr.lac}, PLMN: ${curr.plmn}) via Online DB in background...')
						
						verify_args := AsyncVerifyArgs{
							plmn: curr.plmn
							lac: curr.lac
							cid: curr.cid
							rat: curr.rat
							socks_proxy: socks_proxy
						}
						
						go async_verify_cell_tower(verify_args)
						
						oldplmn = curr.plmn
						oldlac = curr.lac
						oldcid = curr.cid
					}

					trust := calculate_trust(curr, prev_state, nbr)
					if target != '' {
						target_scores[target] = trust.score
					}

					if trust.score < 70 {
						display_trust(trust)
					}
					record_cell(curr, trust.score)

					if trust.score < 50 {
						for m in active_modems {
							send(m, 'AT+ERAT=6')
						}
					}

					// if trust.score < 30 && curr.cid.len > 0 && curr.cid !in blacklist {
					// 	blacklist << curr.cid
					// 	save_blacklist(blacklist)
					// 	println(term.red('Auto-blacklisted ' + curr.cid))
					// 	log_event('AUTO_BLACKLIST ' + curr.cid)
					// }

					// if curr.cid.len > 0 && curr.cid in blacklist {
						// println(term.red('Blacklisted cell ' + curr.cid + ' rotating'))
						// log_event('BLACKLISTED ' + curr.cid)
						// for m in active_modems {
						//	send(m, 'AT+EMMCHLCK=0')
						// }
                        // I'm working on an alternative method to switch so those logs are passive
					// }

					if curr.cid.len > 0 && is_new_cell(curr.cid) {
						println(term.yellow('New cell: ' + curr.cid))
						log_event('NEW_CELL ' + curr.cid)
					}

					prev_state = curr
				}
			}

			if has_input() {
				cmd := os.get_raw_line().trim_space()
				if cmd == 'next' {
					break
				} else if cmd == 'pause' {
					is_paused = !is_paused
					if is_paused {
						sw.pause()
						println(term.yellow('Hopping paused.'))
					} else {
						sw.start()
						println(term.green('Hopping resumed.'))
					}
				} else if cmd == 'list' {
					println('Whitelist: ' + whitelist.str())
					println('Blacklist: ' + blacklist.str())
				} else if cmd == 'status' {
					s := get_cell_state(active_modems[0])
					println('Paused: ' + is_paused.str())
					println('LAC:' + s.lac + ' CID:' + s.cid + ' RAT:' + rat_name(s.rat) +
						' PLMN:' + s.plmn + ' RSSI:' + s.rssi.str())
				} else if cmd == 'trust' {
					s := get_cell_state(active_modems[0])
					n := get_neighbor_count(active_modems[0])
					t := calculate_trust(s, prev_state, n)
					display_trust(t)
				} else if cmd == 'neighbors' {
					resp := query(active_modems[0], 'AT+ECELL')
					println(resp)
					println('Count: ' + count_cells(resp).str())
				} else if cmd == 'scan' {
					for i, m in active_modems {
						s := get_cell_state(m)
						n := get_neighbor_count(m)
						t := calculate_trust(s, prev_state, n)
						println(term.bold('SIM' + (i + 1).str() + ' ' + m))
						println('  LAC:' + s.lac + ' CID:' + s.cid + ' RAT:' + rat_name(s.rat))
						println('  PLMN:' + s.plmn + ' RSSI:' + s.rssi.str() + ' Neighbors:' + n.str())
						display_trust(t)
					}
				} else if cmd == 'history' {
					data := os.read_file(history_path) or { '' }
					lines := data.split('\n').filter(it.len > 0)
					si := if lines.len > 20 { lines.len - 20 } else { 0 }
					for l in lines[si..] {
						println(l)
					}
				} else if cmd == 'lte' {
					for m in active_modems {
						send(m, 'AT+ERAT=6')
					}
					println('Locked to LTE-only')
				} else if cmd.starts_with('at ') || cmd.starts_with('AT ') {
					raw_cmd := cmd[3..].trim_space()
					mut base_cmd := raw_cmd.to_upper()
					if base_cmd.starts_with('AT') {
						base_cmd = base_cmd.all_after('AT')
					}
					is_extended := base_cmd.starts_with('+')
					if is_extended {
						base_cmd = base_cmd.all_after('+')
					}
					if base_cmd.contains('=') {
						base_cmd = base_cmd.split('=')[0].trim_space()
					}
					if base_cmd.contains('?') {
						base_cmd = base_cmd.split('?')[0].trim_space()
					}

					if is_extended && !check_command_support(active_modems[0], base_cmd) {
						println(term.red('Error: Command AT+' + base_cmd + ' is not supported by this modem!'))
					} else {
						for m in active_modems {
							println(m + ': ' + query(m, raw_cmd))
						}
					}
				} else if cmd.starts_with('>') {
					val := cmd[1..].trim_space()
					if val.len > 0 {
						manual_target = val
						break
					}
				} else if cmd.starts_with('+') {
					nv := cmd[1..].trim_space()
					if nv !in whitelist {
						whitelist << nv
						save_list(whitelist)
						println('Added ' + nv)
					}
				} else if cmd.starts_with('-') {
					dv := cmd[1..].trim_space()
					whitelist = whitelist.filter(it != dv)
					save_list(whitelist)
					println('Removed ' + dv)
				} else if cmd.starts_with('!!') {
					bv := cmd[2..].trim_space()
					blacklist = blacklist.filter(it != bv)
					save_blacklist(blacklist)
					println('Unblacklisted ' + bv)
				} else if cmd.starts_with('!') {
					bv := cmd[1..].trim_space()
					if bv.len > 0 && bv !in blacklist {
						blacklist << bv
						save_blacklist(blacklist)
						println('Blacklisted ' + bv)
					}
				} else if cmd.starts_with('~') {
					val := cmd[1..].trim_space()
					if val.len > 0 {
						manual_cid = val
						println('Setting manual CID to ' + val)
						// for m in active_modems {
						//	send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',,3')
						// }
						// time.sleep(1000 * time.millisecond)
						for m in active_modems {
                            send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',' + val + ',0') // I want to prevent modem fallbacks
                            send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',' + val + ',3')
						}
					} else {
						manual_cid = ''
						break
					}
				}
			}

			time.sleep(200 * time.millisecond)
		}

		log_event('ROTATE from ' + target)
		for m in active_modems {
		    // send(m, 'AT+EMMCHLCK=0')
            send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',,0')
	    }
		time.sleep(3 * time.second)
	}
}

fn main() {
	if os.args.len > 1 && os.args[1] == 'wlan' {
		if os.args.len >= 3 {
			run_wlan(os.args[2])
		} else {
			println(term.red('[!] Usage: ' + os.args[0] + ' wlan {apply|restore|status}'))
			exit(1)
		}
		return
	}
	run_hopper()
}
