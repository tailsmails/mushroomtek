import os
import time
import rand
import gg
import sync

struct App {
mut:
	gg              &gg.Context = unsafe { nil }
	active_modems   []string
	whitelist       []string
	blacklist       []string
	prev_state      CellState
	curr_state      CellState
	logs            []string
	is_hopping      bool
	trust_score     int
	target          string
	mtx             &sync.Mutex = sync.new_mutex()
	prev_nbr        int
	tick            int
}

struct CellState {
mut:
	lac  string
	cid  string
	rat  int
	plmn string
	rssi int
}

fn (mut app App) log_event(msg string) {
	timestamp := time.now().format_ss()
	app.mtx.@lock()
	app.logs.insert(0, '${timestamp} | ${msg}')
	if app.logs.len > 50 {
		app.logs.delete_last()
	}
	app.mtx.unlock()
}

fn (mut app App) send_at(path string, cmd string) bool {
	res := os.system('su -c "echo -e \"${cmd}\\r\" > ${path}"')
	return res == 0
}

fn (mut app App) query_at(path string, cmd string) string {
	r_path := '/data/local/tmp/at_resp_v'
	os.system('su -c "rm ${r_path} 2>/dev/null"')
	os.system('su -c "timeout 4 cat ${path} > ${r_path} &"')
	time.sleep(300 * time.millisecond)
	if !app.send_at(path, cmd) {
		return ''
	}
	time.sleep(1500 * time.millisecond)
	res := os.execute('su -c "cat ${r_path}"')
	if res.exit_code != 0 {
		return ''
	}
	return res.output.trim_space()
}

fn (mut app App) count_cells(resp string) int {
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

fn (mut app App) get_neighbor_count(path string) int {
	resp := app.query_at(path, 'AT+ECELL')
	return app.count_cells(resp)
}

fn (mut app App) update_cell_state() {
	app.mtx.@lock()
	modems := app.active_modems.clone()
	app.mtx.unlock()

	if modems.len == 0 { return }
	path := modems[0]

	r_path := '/data/local/tmp/at_resp_state'
	os.system('su -c "rm ${r_path} 2>/dev/null"')
	os.system('su -c "timeout 5 cat ${path} > ${r_path} &"')
	time.sleep(200 * time.millisecond)
	app.send_at(path, 'AT+CEREG?')
	time.sleep(300 * time.millisecond)
	app.send_at(path, 'AT+CGREG?')
	time.sleep(300 * time.millisecond)
	app.send_at(path, 'AT+CSQ')
	time.sleep(1000 * time.millisecond)

	res := os.execute('su -c "cat ${r_path}"')
	if res.exit_code != 0 { return }
	resp := res.output

	mut lac := ''
	mut cid := ''
	mut rat := -1
	mut rssi := -1

	for line in resp.split_into_lines() {
		l := line.trim_space()
		if (l.starts_with('+CGREG:') || l.starts_with('+CEREG:')) && lac == '' {
			parts := l.all_after(':').split(',')
			if parts.len >= 5 {
				lac = parts[2].replace('"', '').trim_space()
				cid = parts[3].replace('"', '').trim_space()
				rat = parts[4].trim_space().int()
			}
		}
		if l.starts_with('+CSQ:') {
			parts := l.all_after(':').split(',')
			if parts.len >= 1 {
				rssi = parts[0].trim_space().int()
			}
		}
	}

	app.mtx.@lock()
	app.curr_state = CellState{lac, cid, rat, '', rssi}
	app.mtx.unlock()
}

fn (mut app App) calculate_trust(nbr int) {
	app.mtx.@lock()
	curr := app.curr_state
	prev := app.prev_state
	app.mtx.unlock()

	mut score := 100

	if nbr > 2 {
		score -= 20
	}
	if prev.rat == 7 && curr.rat >= 0 && curr.rat <= 3 {
		score -= 30
	} else if prev.rat == 7 && curr.rat >= 2 && curr.rat <= 6 {
		score -= 15
	}
	if curr.rssi > 0 && curr.rssi != 99 && curr.rssi > 28 {
		score -= 15
	}
	if prev.lac != '' && curr.lac != prev.lac && curr.lac != '' {
		score -= 20
	}
	if score < 0 { score = 0 }

	app.mtx.@lock()
	app.trust_score = score
	app.mtx.unlock()
}

fn (mut app App) get_total_rx() i64 {
	mut total := i64(0)
	ifaces := ['ccmni0', 'ccmni1', 'ccmni2', 'rmnet0', 'rmnet1', 'rmnet_data0', 'rmnet_data1']
	for iface in ifaces {
		res := os.execute('cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null')
		if res.exit_code == 0 {
			total += res.output.trim_space().i64()
		}
	}
	return total
}

fn (mut app App) is_heavy_traffic() bool {
	rx1 := app.get_total_rx()
	time.sleep(1 * time.second)
	rx2 := app.get_total_rx()
	return (rx2 - rx1) > 512000
}

fn (mut app App) hop() {
	app.mtx.@lock()
	if !app.is_hopping {
		app.mtx.unlock()
		return
	}
	if app.whitelist.len == 0 {
		app.mtx.unlock()
		return
	}
	target := rand.element(app.whitelist) or { '0' }
	modems := app.active_modems.clone()
	app.mtx.unlock()

	app.log_event('Hopping to EARFCN: ${target}')

	for m in modems {
		app.send_at(m, 'AT+ERAT=6')
		app.send_at(m, 'AT+EPBSE=154,155,4,0,0,0,0,0,0,0')
		app.send_at(m, 'AT+ESBP=1,6,0') // Disable Neighbor Cell Measurement Reports
		time.sleep(200 * time.millisecond)
		app.send_at(m, 'AT+EMMCHLCK=1,7,0,${target},,3')
	}

	app.mtx.@lock()
	app.target = target
	app.mtx.unlock()
}

fn frame(mut app App) {
	app.gg.begin()

	app.mtx.@lock()
	is_hopping := app.is_hopping
	target := app.target
	curr_state := app.curr_state
	trust_score := app.trust_score
	logs := app.logs.clone()
	app.mtx.unlock()

	// Dashboard
	app.gg.draw_text(20, 20, 'Mushroomtek - MTK Stealth', gg.TextCfg{size: 30, color: gg.white})

	y_offset := 70
	app.gg.draw_text(20, y_offset, 'Status: ${if is_hopping { "Hopping" } else { "Idle" }}', gg.TextCfg{size: 20, color: if is_hopping { gg.green } else { gg.yellow }})
	app.gg.draw_text(20, y_offset + 30, 'EARFCN: ${target}', gg.TextCfg{size: 20})
	app.gg.draw_text(20, y_offset + 60, 'LAC: ${curr_state.lac}  CID: ${curr_state.cid}', gg.TextCfg{size: 20})

	trust_color := if trust_score >= 70 { gg.green } else if trust_score >= 40 { gg.yellow } else { gg.red }
	app.gg.draw_text(20, y_offset + 90, 'Trust Score: ${trust_score}/100', gg.TextCfg{size: 25, color: trust_color})

	// Controls
	app.gg.draw_rect_filled(20, y_offset + 130, 150, 40, if is_hopping { gg.red } else { gg.green })
	app.gg.draw_text(40, y_offset + 140, if is_hopping { 'STOP' } else { 'START' }, gg.TextCfg{size: 20, color: gg.black})

	// Logs
	app.gg.draw_text(20, y_offset + 190, 'Recent Logs:', gg.TextCfg{size: 20, color: gg.gray})
	for i, log in logs {
		if i > 15 { break }
		app.gg.draw_text(20, y_offset + 220 + (i * 25), log, gg.TextCfg{size: 16})
	}

	app.gg.end()
}

fn on_click(x f32, y f32, btn gg.MouseButton, mut app App) {
	if btn != .left { return }

	y_offset := 70
	if x >= 20 && x <= 170 && y >= y_offset + 130 && y <= y_offset + 170 {
		app.mtx.@lock()
		app.is_hopping = !app.is_hopping
		state := app.is_hopping
		modems := app.active_modems.clone()
		app.mtx.unlock()

		if !state {
			app.log_event('Stopping...')
			for m in modems {
				app.send_at(m, 'AT+EMMCHLCK=0')
			}
		} else {
			app.log_event('Starting...')
		}
	}
}

fn main() {
	mut app := &App{
		whitelist: ['1850', '1300']
		is_hopping: false
		trust_score: 100
		prev_nbr: -1
	}

	if os.exists('/dev/radio/atci1') { app.active_modems << '/dev/radio/atci1' }
	if os.exists('/dev/radio/atci2') { app.active_modems << '/dev/radio/atci2' }

	app.gg = gg.new_context(
		width: 600
		height: 900
		window_title: 'Mushroomtek'
		frame_fn: frame
		click_fn: on_click
		user_data: app
	)

	// Start background thread for modem logic
	spawn fn (mut app App) {
		for {
			app.mtx.@lock()
			is_hopping := app.is_hopping
			modems := app.active_modems.clone()
			app.mtx.unlock()

			if is_hopping && modems.len > 0 {
				app.hop()

				dwell := rand.int_in_range(15, 45) or { 30 }
				for _ in 0 .. (dwell * 2) {
					app.mtx.@lock()
					still_hopping := app.is_hopping
					app.mtx.unlock()
					if !still_hopping { break }

					if app.is_heavy_traffic() {
						app.log_event('Heavy traffic, delaying hop...')
						time.sleep(10 * time.second)
						continue
					}

					app.update_cell_state()
					nbr := app.get_neighbor_count(modems[0])
					app.calculate_trust(nbr)

					app.mtx.@lock()
					trust := app.trust_score
					cid := app.curr_state.cid
					if trust < 30 && cid != '' && cid !in app.blacklist {
						app.blacklist << cid
						app.log_event('Auto-blacklisted: ${cid}')
					}
					if cid != '' && cid in app.blacklist {
						app.log_event('Blacklisted cell ${cid} detected, rotating...')
						app.mtx.unlock()
						break
					}
					app.prev_state = app.curr_state
					app.mtx.unlock()

					time.sleep(500 * time.millisecond)
				}
			} else {
				time.sleep(1 * time.second)
			}
		}
	}(mut app)

	app.gg.run()
}
