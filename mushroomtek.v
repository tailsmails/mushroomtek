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

const band_lock_mask   = 'AT+EPBSE=154,155,4,0,0,0,0,0,0,0'
const band_unlock_mask = 'AT+EPBSE=154,155,168165599,928,0,0,0,0,0,0'

fn send(path string, cmd string) {
	os.system('echo -e "${cmd}\r" > $path')
}

fn has_input() bool {
	mut pfd := C.pollfd{
		fd:      0
		events:  1
		revents: 0
	}
	res := C.poll(&pfd, 1, 0)
	return res > 0
}

fn hr() {
	println(term.dim('  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'))
}

fn header() {
	println('')
	println(term.bold(term.magenta('       __  ___           __                   ')))
	println(term.bold(term.magenta('      /  |/  /_  _______/ /_  _________  ____ ')))
	println(term.bold(term.magenta('     / /|_/ / / / / ___/ __ \\/ ___/ __ \\/ __ \\')))
	println(term.bold(term.magenta('    / /  / / /_/ (__  ) / / / /  / /_/ / /_/ /')))
	println(term.bold(term.magenta('   /_/  /_/\\__,_/____/_/ /_/_/   \\____/\\____/ ')))
	println(term.bold(term.magenta('                                    ') + term.dim('tek v1.0')))
	println('')
	hr()
	println('')
}

fn main() {
	header()

	mut active_modems := []string{}
	if os.exists('/dev/radio/atci1') { active_modems << '/dev/radio/atci1' }

	print('  ${term.bold('?')} Protect SIM2? ${term.dim('y/n')} > ')
	sim2 := os.input('')
	if os.exists('/dev/radio/atci2') && sim2 == 'y' { active_modems << '/dev/radio/atci2' }

	if active_modems.len == 0 {
		println('  ${term.red('x')} No radio interfaces found.')
		exit(1)
	}

	os.signal_opt(.int, fn [active_modems] (_ os.Signal) {
		println('')
		hr()
		println('  ${term.yellow('!')} Restoring bands...')
		for m in active_modems {
			send(m, 'AT+ESBP=1,6,1')
			send(m, 'AT+CURC=1')
			send(m, 'AT+EMMCHLCK=0')
			send(m, band_unlock_mask)
			send(m, 'AT+ERAT=0')
			send(m, 'AT+CEMODE=0')
		}
		println('  ${term.green('*')} Done.')
		hr()
		exit(0)
	}) or {}

	print('  ${term.bold('?')} EARFCNs ${term.dim('(e.g. 1234,5678)')} > ')
	user_input := os.input('')
	mut whitelist := []string{}
	for rp in user_input.split(',') {
		val := rp.trim_space()
		if val.len > 0 { whitelist << val }
	}
	if whitelist.len == 0 { whitelist << '0' }

	println('')
	hr()
	println('')
	println('  ${term.bold(term.green('*'))} ${term.bold('mushroomtek ready')}')
	println('')
	println('  ${term.dim('next')}       ${term.dim('skip timer')}')
	println('  ${term.dim('>earfcn')}    ${term.dim('force lock')}')
	println('  ${term.dim('+earfcn')}    ${term.dim('add to list')}')
	println('  ${term.dim('-earfcn')}    ${term.dim('remove from list')}')
	println('  ${term.dim('list')}       ${term.dim('show whitelist')}')
	println('')
	hr()

	mut manual_target := ''

	for {
		mut target := ''
		if manual_target != '' {
			target = manual_target
			manual_target = ''
			println('')
			println('  ${term.bold(term.red('MANUAL'))} >> ${term.bold(target)}')
		} else {
			if whitelist.len == 0 { whitelist << '0' }
			target = rand.element(whitelist) or { whitelist[0] }
			println('')
			println('  ${term.bold(term.cyan('AUTO'))}   >> ${term.bold(target)}')
		}

		for m in active_modems {
			send(m, 'AT+ESBP=1,6,0')
			send(m, 'AT+CURC=0')
			send(m, 'AT+ERAT=3')
			send(m, 'AT+CEMODE=2')
			send(m, band_lock_mask)
			time.sleep(500 * time.millisecond)
			send(m, 'AT+EMMCHLCK=1,7,0,${target},,3')
		}

		delay := rand.int_in_range(900, 2700) or { 1200 }
		println('  ${term.dim('hold')} ${delay / 60}${term.dim('m')}')

		start_time := time.now()

		for {
			if time.since(start_time).seconds() >= delay { break }

			if has_input() {
				cmd := os.get_raw_line().trim_space()

				if cmd == 'next' {
					println('  ${term.yellow('>')} skip')
					break
				} else if cmd == 'list' {
					println('  ${term.cyan('*')} ${whitelist}')
				} else if cmd.starts_with('>') {
					val := cmd[1..].trim_space()
					if val.len > 0 {
						manual_target = val
						println('  ${term.yellow('>')} jump ${term.bold(val)}')
						break
					}
				} else if cmd.starts_with('+') {
					new_val := cmd[1..]
					if new_val !in whitelist {
						whitelist << new_val
						println('  ${term.green('+')} ${new_val}')
					}
				} else if cmd.starts_with('-') {
					del_val := cmd[1..]
					whitelist = whitelist.filter(it != del_val)
					println('  ${term.red('-')} ${del_val}')
				}
			}

			time.sleep(200 * time.millisecond)
		}

		println('  ${term.dim('rotating...')}')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
		}
		time.sleep(2 * time.second)
		hr()
	}
}