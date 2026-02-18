//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

// v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O2 -fPIE -fno-stack-protector -fno-ident -fno-common -fvisibility=hidden" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,--gc-sections -Wl,--build-id=none" mushroomtek.v -o mushroomtek && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version --remove-section=.note.ABI-tag --remove-section=.note.gnu.build-id --remove-section=.note.android.ident --remove-section=.eh_frame --remove-section=.eh_frame_hdr mushroomtek

import os
import time
import rand
import term

#include <poll.h>

struct C.pollfd {
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u32, timeout int) int

const band_lock_mask = 'AT+EPBSE=154,155,4,0,0,0,0,0,0,0'
const band_unlock_mask = 'AT+EPBSE=154,155,168165599,928,0,0,0,0,0,0'
const save_path = '/data/local/tmp/hopper.list'
const log_path = '/data/local/tmp/hopper.log'
const resp_path = '/data/local/tmp/at_resp'

struct CellState {
mut:
	lac  string
	cid  string
	rat  int
	plmn string
	rssi int
}

fn send(path string, cmd string) {
	os.system('echo -e "${cmd}\r" > $path')
}

fn query(path string, cmd string) string {
	os.rm(resp_path) or {}
	os.system('timeout 4 cat ' + path + ' > ' + resp_path + ' &')
	time.sleep(300 * time.millisecond)
	send(path, cmd)
	time.sleep(2 * time.second)
	result := os.read_file(resp_path) or { return '' }
	return result.trim_space()
}

fn get_cell_state(path string) CellState {
	mut state := CellState{ rat: -1, rssi: -1 }
	os.rm(resp_path) or {}
	os.system('timeout 6 cat ' + path + ' > ' + resp_path + ' &')
	time.sleep(300 * time.millisecond)
	send(path, 'AT+CEREG?')
	time.sleep(400 * time.millisecond)
	send(path, 'AT+CGREG?')
	time.sleep(400 * time.millisecond)
	send(path, 'AT+COPS?')
	time.sleep(400 * time.millisecond)
	send(path, 'AT+CSQ')
	time.sleep(1500 * time.millisecond)
	resp := os.read_file(resp_path) or { return state }

	for line in resp.split_into_lines() {
		l := line.trim_space()
		if (l.starts_with('+CGREG:') || l.starts_with('+CEREG:')) && state.lac.len == 0 {
			parts := l.all_after(':').split(',')
			if parts.len >= 5 {
				state.lac = parts[2].replace('"', '').trim_space()
				state.cid = parts[3].replace('"', '').trim_space()
				state.rat = parts[4].trim_space().int()
			}
		}
		if l.starts_with('+COPS:') || l.starts_with('+EOPS:') {
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
			send(m, 'AT+ERAT=3')
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
	os.write_file(save_path, list.join('\n')) or {}
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

fn main() {
	mut active_modems := []string{}
	if os.exists('/dev/radio/atci1') {
		active_modems << '/dev/radio/atci1'
	}

	print('Protect SIM2? (y/n): ')
	if os.exists('/dev/radio/atci2') && os.input('') == 'y' {
		active_modems << '/dev/radio/atci2'
	}

	if active_modems.len == 0 {
		println(term.red('No radio interfaces found.'))
		exit(1)
	}

	os.signal_opt(.int, fn [active_modems] (_ os.Signal) {
		println('\nRestoring...')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
			send(m, band_unlock_mask)
			send(m, 'AT+ERAT=0')
		}
		log_event('EXIT')
		exit(0)
	}) or {}

	mut whitelist := load_list()
	if whitelist.len > 0 {
		println('Saved: ' + whitelist.str())
		print('Use saved? (y/n): ')
		if os.input('') != 'y' {
			whitelist = []
		}
	}
	if whitelist.len == 0 {
		print('EARFCNs: ')
		for rp in os.input('').split(',') {
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

	for m in active_modems {
		send(m, 'AT+CEREG=2')
		time.sleep(200 * time.millisecond)
		send(m, 'AT+CGREG=3')
		time.sleep(200 * time.millisecond)
	}

	log_event('START ' + whitelist.str())
	println('Commands: next | list | status | at CMD | >EARFCN | +EARFCN | -EARFCN')

	mut manual_target := ''
	mut prev_state := CellState{ rat: -1, rssi: -1 }
	mut tick := 0

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
			target = rand.element(whitelist) or { whitelist[0] }
			println('\n>>> Auto: ' + term.green(target))
		}

		for m in active_modems {
			send(m, 'AT+ERAT=3')
			send(m, band_lock_mask)
			time.sleep(500 * time.millisecond)
			send(m, 'AT+EMMCHLCK=1,7,0,' + target + ',,3')
		}
		log_event('LOCK ' + target)

		delay := rand.int_in_range(900, 2700) or { 1200 }
		println('Wait ' + (delay / 60).str() + 'm')
		start := time.now()
		tick = 0

		for {
			if time.since(start).seconds() >= delay {
				break
			}

			tick++
			if tick >= 300 && !has_input() {
				tick = 0
				curr := get_cell_state(active_modems[0])
				if curr.lac.len > 0 {
					check_anomalies(prev_state, curr, active_modems)
					prev_state = curr
				}
			}

			if has_input() {
				cmd := os.get_raw_line().trim_space()
				if cmd == 'next' {
					break
				} else if cmd == 'list' {
					println(whitelist.str())
				} else if cmd == 'status' {
					s := get_cell_state(active_modems[0])
					println('LAC:' + s.lac + ' CID:' + s.cid + ' RAT:' + rat_name(s.rat) +
						' PLMN:' + s.plmn + ' RSSI:' + s.rssi.str())
				} else if cmd.starts_with('at ') || cmd.starts_with('AT ') {
					for m in active_modems {
						println(m + ': ' + query(m, cmd[3..].trim_space()))
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
				}
			}

			time.sleep(200 * time.millisecond)
		}

		log_event('ROTATE from ' + target)
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
		}
		time.sleep(2 * time.second)
	}
}