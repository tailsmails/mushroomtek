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

fn rule() {
	println(term.dim('  ────────────────────────────────────────'))
}

fn main() {
	println('')
	println(term.bold(term.cyan('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')))
	println(term.bold('        ⚡  EARFCN Band Locker  ⚡'))
	println(term.bold(term.cyan('  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')))
	println('')

	mut active_modems := []string{}
	if os.exists('/dev/radio/atci1') { active_modems << '/dev/radio/atci1' }

	print('  ${term.bold(term.yellow('?'))} Protect SIM2? ${term.dim('[y/n]')} ${term.dim('›')} ')
	sim2 := os.input('')
	if os.exists('/dev/radio/atci2') && sim2 == 'y' { active_modems << '/dev/radio/atci2' }

	if active_modems.len == 0 {
		println('  ${term.bold(term.red('✗'))} ${term.red('No radio interfaces found.')}')
		exit(1)
	}

	os.signal_opt(.int, fn [active_modems] (_ os.Signal) {
		println('\n  ${term.bold(term.yellow('⚠  Emergency Exit — Restoring Bands…'))}')
		for m in active_modems {
			send(m, 'AT+ESBP=1,6,1')
			send(m, 'AT+CURC=1')
			send(m, 'AT+EMMCHLCK=0')
			send(m, band_unlock_mask)
			send(m, 'AT+ERAT=0')
			send(m, 'AT+CEMODE=0')
		}
		println('  ${term.green('✔')} ${term.dim('Bands restored.')}')
		exit(0)
	}) or {}

	rule()
	print('  ${term.bold(term.blue('◈'))} Enter EARFCNs ${term.dim('(e.g. 1234,56789)')} ${term.dim('›')} ')
	user_input := os.input('')
	mut whitelist := []string{}
	for rp in user_input.split(',') {
		val := rp.trim_space()
		if val.len > 0 { whitelist << val }
	}
	if whitelist.len == 0 { whitelist << '0' }

	rule()
	println('')
	println('  ${term.bold(term.green('✔'))} ${term.bold('System Online')}')
	println('')
	println(term.bold('  ┌─── Commands ─────────────────────────'))
	println('  ${term.bold('│')}   ${term.cyan('next')}        ${term.dim('Skip current timer')}')
	println('  ${term.bold('│')}   ${term.cyan('>earfcn')}     ${term.dim('Force lock to EARFCN')}')
	println('  ${term.bold('│')}   ${term.cyan('+earfcn')}     ${term.dim('Add EARFCN to list')}')
	println('  ${term.bold('│')}   ${term.cyan('-earfcn')}     ${term.dim('Remove EARFCN from list')}')
	println('  ${term.bold('│')}   ${term.cyan('list')}        ${term.dim('Show current whitelist')}')
	println(term.bold('  └─────────────────────────────────────'))
	println('')

	mut manual_target := ''

	for {
		mut target := ''
		if manual_target != '' {
			target = manual_target
			manual_target = ''
			println('\n  ${term.bold(term.red('⚡ MANUAL'))}  ${term.dim('→')}  Locking to ${term.bold(term.green(target))}')
		} else {
			if whitelist.len == 0 { whitelist << '0' }
			target = rand.element(whitelist) or { whitelist[0] }
			println('\n  ${term.bold(term.blue('↻ AUTO'))}    ${term.dim('→')}  Locking to ${term.bold(term.green(target))}')
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
		println('  ${term.dim('◷ Locked ·')} waiting ${term.bold('${delay / 60}')} min')

		start_time := time.now()

		for {
			if time.since(start_time).seconds() >= delay { break }

			if has_input() {
				cmd := os.get_raw_line().trim_space()

				if cmd == 'next' {
					println('  ${term.yellow('⏭')} Skipping…')
					break
				} else if cmd == 'list' {
					println('  ${term.blue('◈')} ${term.bold('Whitelist:')} ${whitelist}')
				} else if cmd.starts_with('>') {
					val := cmd[1..].trim_space()
					if val.len > 0 {
						manual_target = val
						println('  ${term.yellow('⚡')} Jumping to ${term.bold(val)}')
						break
					}
				} else if cmd.starts_with('+') {
					new_val := cmd[1..]
					if new_val !in whitelist {
						whitelist << new_val
						println('  ${term.green('✚')} Added ${term.bold(new_val)}')
					}
				} else if cmd.starts_with('-') {
					del_val := cmd[1..]
					whitelist = whitelist.filter(it != del_val)
					println('  ${term.red('✗')} Removed ${term.bold(del_val)}')
				}
			}

			time.sleep(200 * time.millisecond)
		}

		println('  ${term.dim('⟳ Rotating…')}')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
		}
		time.sleep(2 * time.second)
		rule()
	}
}