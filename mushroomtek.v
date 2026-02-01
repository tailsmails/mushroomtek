// v -prod -gc boehm -prealloc -skip-unused -d no_backtrace -d no_debug -cc clang -cflags "-O3 -flto -fPIE -fstack-protector-all -fstack-clash-protection -D_FORTIFY_SOURCE=3 -fno-ident -fno-common -fwrapv -ftrivial-auto-var-init=zero -fvisibility=hidden -Wformat -Wformat-security -Werror=format-security" -ldflags "-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--gc-sections -Wl,--icf=all -Wl,--build-id=none" mushroomtek.v -o mushroomtek && strip --strip-all --remove-section=.comment --remove-section=.note --remove-section=.gnu.version mushroomtek

import os
import time
import rand
import term

fn info(msg string) { println('${term.blue('ℹ')} ${msg}') }
fn success(msg string) { println('${term.green('✔')} ${msg}') }
fn warn(msg string) { println('${term.yellow('⚠')} ${msg}') }
fn fatal(msg string) { println('${term.bg_red(term.white(' FATAL '))} ${msg}'); exit(1) }

fn send(path string, cmd string) { os.system('echo -e "${cmd}\\r" > $path') }

fn main() {
	mut active_modems := []string{}
	if os.exists('/dev/radio/atci1') { active_modems << '/dev/radio/atci1' }
	info("Do you want to protect SIM2? (y/any)")
	sim2 := os.input('')
	if os.exists('/dev/radio/atci2') && sim2 == "y" { active_modems << '/dev/radio/atci2' }

	if active_modems.len == 0 { fatal('No radio interfaces found. Root required.') }

	os.signal_opt(.int, fn [active_modems] (_ os.Signal) {
		println('\n')
		for m in active_modems { os.system('echo -e "AT+EMMCHLCK=0\\r" > $m') }
		warn('Emergency reset complete. Modem unlocked.')
		exit(0)
	}) or {}

	info('Interfaces: ${active_modems}')
	print('${term.blue('ℹ')} Enter Whitelist EARFCNs (e.g. 1234,56789,...): ')
	user_input := os.input('')
	
	mut whitelist := []string{}
	raw_parts := user_input.split(',')
	for rp in raw_parts {
		val := rp.trim_space()
		if val.len > 0 { whitelist << val }
	}

	if whitelist.len == 0 { fatal('No EARFCNs provided.') }

	success('Hopping sequence starting for: ${whitelist}')

	for {
		target := rand.element(whitelist) or { whitelist[0] }
		info('Stealth Hop -> Target EARFCN: ${target}')

		for m in active_modems {
			send(m, 'AT+ERAT=3')
			send(m, 'AT+EMMCHLCK=1,7,0,${target},0,3')
		}

		delay := rand.int_in_range(900, 2700) or { 1200 }
		info('Lock active. Next rotation in ${delay / 60} minutes...')
		time.sleep(delay * time.second)
		
		for m in active_modems { send(m, 'AT+EMMCHLCK=0') }
		time.sleep(10 * time.second)
	}
}