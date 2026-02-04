// frida -p $(pidof com.mediatek.engineermode) -l washroomtek.js

console.log("[*] WiFi Washroom Mode (LPI Profile)...");

var libName = "libem_wifi_jni.so";
var hijackedEnv = null;
var hijackedClass = null;

var interval = setInterval(function() {
    var module = Process.findModuleByName(libName);
    if (module) {
        clearInterval(interval);
        var symbols = module.enumerateSymbols();
        var funcs = {};
        
        for(var i=0; i<symbols.length; i++) {
            if(symbols[i].name.indexOf("getFwManifestVersion") !== -1 && symbols[i].name.indexOf("JNIEnv") !== -1) {
                funcs["trigger"] = symbols[i].address;
            }
            if(symbols[i].name.indexOf("SetTxPower") !== -1 && symbols[i].name.indexOf("JNIEnv") !== -1) {
                funcs["pwr"] = symbols[i].address;
            }
            if(symbols[i].name.indexOf("hqaGetTxPower") !== -1 && symbols[i].name.indexOf("JNIEnv") !== -1) {
                funcs["get_pwr"] = symbols[i].address;
            }
        }

        if (funcs["trigger"] && funcs["pwr"]) {
            Interceptor.attach(funcs["trigger"], {
                onEnter: function(args) {
                    if (!hijackedEnv) {
                        hijackedEnv = args[0];
                        hijackedClass = args[1];
                        console.log("\n[+] Stealth Protocol Initiated...");
                        enableGhostMode(funcs);
                    }
                }
            });
            console.log("[*] READY. Open WiFi settings to vanish.");
        }
    }
}, 500);

function enableGhostMode(funcs) {
    var setPwr = new NativeFunction(funcs["pwr"], 'int', ['pointer', 'pointer', 'int', 'int', 'int', 'int', 'int']);
    var getPwr = funcs["get_pwr"] ? new NativeFunction(funcs["get_pwr"], 'int', ['pointer', 'pointer', 'int', 'int']) : null;
    var stealthPower = 4; 

    console.log("[*] Reducing Thermal/RF Signature to " + stealthPower + " dBm...");
    
    setPwr(hijackedEnv, hijackedClass, 0, 0, stealthPower, 0, 0);
    setPwr(hijackedEnv, hijackedClass, 1, 0, stealthPower, 0, 0);

    Thread.sleep(0.5);

    if (getPwr) {
        var current = getPwr(hijackedEnv, hijackedClass, 0, 0);
        console.log("[+] Current Signature Level: " + current + " dBm");
        if (current <= 6) {
            console.log("[!!!] WASHROOM MODE ACTIVE. Your signal barely leaves the room.");
        } else {
            console.log("[-] Driver limited the reduction. Current: " + current);
        }
    }
}