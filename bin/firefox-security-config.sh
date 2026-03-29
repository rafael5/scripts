bash -c '
PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -type d -name "*.default-release" | head -n 1);
[ -z "$PROFILE" ] && PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -type d -name "*.default" | head -n 1);

mkdir -p "$PROFILE";

cat > "$PROFILE/user.js" << "EOF"
// Privacy hardening

user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.firstparty.isolate", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("network.cookie.cookieBehavior", 5);

// WebRTC leak prevention
user_pref("media.peerconnection.enabled", false);

// Disable geolocation
user_pref("geo.enabled", false);

// Disable battery API
user_pref("dom.battery.enabled", false);

// Disable pings
user_pref("browser.send_pings", false);

// Disable DNS prefetch
user_pref("network.dns.disablePrefetch", true);

// Enable HTTPS-only mode
user_pref("dom.security.https_only_mode", true);

// Disable telemetry
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);

// DNS over HTTPS
user_pref("network.trr.mode", 2);
user_pref("network.trr.uri", "https://cloudflare-dns.com/dns-query");

EOF

echo "Applied Firefox privacy hardening to: $PROFILE"
'