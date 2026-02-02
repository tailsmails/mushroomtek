// v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O3 -flto -fPIE -fstack-protector-all -fstack-clash-protection -D_FORTIFY_SOURCE=3 -fno-ident -fno-common -fwrapv -ftrivial-auto-var-init=zero -fvisibility=hidden -Wformat -Wformat-security -Werror=format-security" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--gc-sections -Wl,--icf=all -Wl,--build-id=none" mushroomtek.v -o mushroomtek && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version mushroomtek

import os
import time
import rand
import term

fn send(path string, cmd string) { 
	os.system('echo -e "${cmd}\r" > $path') 
}

fn input_listener(cmd_chan chan string) {
	for {
		line := os.input('')
		cmd_chan <- line
	}
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
		println('\n${term.yellow('Exiting... Unlocking modems.')}')
		for m in active_modems { os.system('echo -e "AT+EMMCHLCK=0\\r" > $m') }
		exit(0)
	}) or {}
	
	print('${term.blue('Initial List')} Enter EARFCNs (e.g. 1234,56789): ')
	user_input := os.input('')
	mut whitelist := []string{}
	for rp in user_input.split(',') {
		val := rp.trim_space()
		if val.len > 0 { whitelist << val }
	}

	if whitelist.len == 0 { 
		println('List is empty. Adding default "0".')
		whitelist << '0' 
	}

	println('${term.green('System Ready.')}')
	println('Commands: "+1234" (add), "-1234" (del), "list", "next" (skip wait)')
	
	cmd_chan := chan string{cap: 10}
	spawn input_listener(cmd_chan)
	
	for {
		if whitelist.len == 0 { whitelist << '0' }
		target := rand.element(whitelist) or { whitelist[0] }
		
		println('\n${term.bold('>>>')} Switching to EARFCN: ${term.green(target)}')
		
		for m in active_modems {
			send(m, 'AT+ERAT=3')
			send(m, 'AT+EMMCHLCK=1,7,0,${target},0,3')
		}
		
		delay := rand.int_in_range(900, 2700) or { 1200 }
		println('Locked. Waiting ${delay / 60} minutes. (Type command to interrupt)')
		
		start_time := time.now()
		mut force_skip := false

		for {
			if time.since(start_time).seconds() >= delay { break }
			if force_skip { break }
			
			select {
				cmd := <-cmd_chan {
					trimmed := cmd.trim_space()
					if trimmed == 'next' {
						println('Skipping timer...')
						force_skip = true
					} else if trimmed == 'list' {
						println('${term.blue('Current Whitelist:')} ${whitelist}')
					} else if trimmed.starts_with('+') {
						new_earfcn := trimmed[1..]
						if new_earfcn !in whitelist {
							whitelist << new_earfcn
							println('${term.green('Added:')} ${new_earfcn}')
						}
					} else if trimmed.starts_with('-') {
						del_earfcn := trimmed[1..]
						if del_earfcn in whitelist {
							whitelist = whitelist.filter(it != del_earfcn)
							println('${term.red('Removed:')} ${del_earfcn}')
						}
					} else {
						println('Unknown command. Use: +1234, -1234, list, next')
					}
				}
				else {
					time.sleep(100 * time.millisecond)
				}
			}
		}
		println('Releasing lock temporarily...')
		for m in active_modems { send(m, 'AT+EMMCHLCK=0') }
		time.sleep(5 * time.second)
	}
}