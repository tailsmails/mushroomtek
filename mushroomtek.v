// v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O3 -flto -fPIE -fstack-protector-all -fstack-clash-protection -D_FORTIFY_SOURCE=3 -fno-ident -fno-common -fwrapv -ftrivial-auto-var-init=zero -fvisibility=hidden -Wformat -Wformat-security -Werror=format-security" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--gc-sections -Wl,--icf=all -Wl,--build-id=none" mushroomtek_pro.v -o mushroomtek_pro && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version mushroomtek_pro

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

fn send(path string, cmd string) {
	os.system('echo -e "${cmd}\r" > $path')
}

fn has_input() bool {
	mut pfd := C.pollfd{
		fd: 0
		events: 1
		revents: 0
	}
	res := C.poll(&pfd, 1, 0)
	return res > 0
}

fn main() {
	mut active_modems := []string{}
	if os.exists('/dev/radio/atci1') { active_modems << '/dev/radio/atci1' }
	
	println('${term.yellow('?')} Protect SIM2? (y/n): ')
	sim2 := os.input('')
	if os.exists('/dev/radio/atci2') && sim2 == "y" { active_modems << '/dev/radio/atci2' }

	if active_modems.len == 0 {
		println('${term.red('Error:')} No radio interfaces found.')
		exit(1)
	}

	os.signal_opt(.int, fn [active_modems] (_ os.Signal) {
		println('\n${term.yellow('Emergency Exit... Restoring Bands.')}')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
			send(m, band_unlock_mask)
		}
		exit(0)
	}) or {}

	print('${term.blue('Config')} Enter EARFCNs (e.g. 1234,56789): ')
	user_input := os.input('')
	mut whitelist := []string{}
	for rp in user_input.split(',') {
		val := rp.trim_space()
		if val.len > 0 { whitelist << val }
	}
	if whitelist.len == 0 { whitelist << '0' }

	println('${term.green('System Ready.')} Commands: next, list, +123, -123')

	for {
		if whitelist.len == 0 { whitelist << '0' }
		target := rand.element(whitelist) or { whitelist[0] }
		
		println('\n${term.bold('>>>')} Locking: Band + EARFCN ${term.green(target)}')

		for m in active_modems {
			send(m, 'AT+ERAT=3')
			send(m, band_lock_mask)
			time.sleep(1000 * time.millisecond)
			send(m, 'AT+EMMCHLCK=1,7,0,${target},0,0')
		}

		delay := rand.int_in_range(900, 2700) or { 1200 }
		println('Locked. Waiting ${delay / 60} mins. (Type command anytime)')

		start_time := time.now()
		
		for {
			if time.since(start_time).seconds() >= delay { break }
			
			if has_input() {
				cmd := os.get_raw_line().trim_space()
				if cmd == 'next' {
					println('Skipping timer...')
					break
				} else if cmd == 'list' {
					println('${term.blue('Whitelist:')} ${whitelist}')
				} else if cmd.starts_with('+') {
					new_val := cmd[1..]
					if new_val !in whitelist {
						whitelist << new_val
						println('${term.green('Added:')} ${new_val}')
					}
				} else if cmd.starts_with('-') {
					del_val := cmd[1..]
					whitelist = whitelist.filter(it != del_val)
					println('${term.red('Removed:')} ${del_val}')
				}
			}
			
			time.sleep(200 * time.millisecond)
		}

		println('Rotating Parameters...')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
		}
		time.sleep(3 * time.second)
	}
}