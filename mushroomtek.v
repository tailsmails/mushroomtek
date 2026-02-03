//v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O2 -fPIE -fno-stack-protector -fno-ident -fno-common -fvisibility=hidden" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,--gc-sections -Wl,--build-id=none" mushroomtek.v -o mushroomtek && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version mushroomtek

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
			send(m, 'AT+ESBP=1,6,1')
			send(m, 'AT+CURC=1')
			send(m, 'AT+EMMCHLCK=0')
			send(m, band_unlock_mask)
			send(m, 'AT+ERAT=0')
			send(m, 'AT+CEMODE=0')
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

	println('${term.green('System Ready.')}')
	println('Commands:')
	println('  next      -> Skip timer')
	println('  >1850     -> Force connect to EARFCN 1850 immediately')
	println('  +1850     -> Add to loop list')
	println('  -1850     -> Remove from loop list')
	
	mut manual_target := ''

	for {
		mut target := ''
		if manual_target != '' {
			target = manual_target
			manual_target = ''
			println('\n${term.bold('>>>')} ${term.red('MANUAL OVERRIDE:')} Locking to ${term.green(target)}')
		} else {
			if whitelist.len == 0 { whitelist << '0' }
			target = rand.element(whitelist) or { whitelist[0] }
			println('\n${term.bold('>>>')} Auto Loop: Locking to ${term.green(target)}')
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
		println('Locked. Waiting ${delay / 60} mins.')

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
				} else if cmd.starts_with('>') {
					val := cmd[1..].trim_space()
					if val.len > 0 {
						manual_target = val
						println('${term.yellow('Command received:')} Jumping to ${val}...')
						break
					}
				} else if cmd.starts_with('+') {
					new_val := cmd[1..]
					if new_val !in whitelist {
						whitelist << new_val
						println('${term.green('Added to list:')} ${new_val}')
					}
				} else if cmd.starts_with('-') {
					del_val := cmd[1..]
					whitelist = whitelist.filter(it != del_val)
					println('${term.red('Removed from list:')} ${del_val}')
				}
			}
			
			time.sleep(200 * time.millisecond)
		}

		println('Rotating Parameters...')
		for m in active_modems {
			send(m, 'AT+EMMCHLCK=0')
		}
		time.sleep(2 * time.second)
	}
}