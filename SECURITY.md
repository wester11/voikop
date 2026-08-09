# Security policy

Report a suspected secret or vulnerability privately to the VOID support team;
do not create a public issue containing a token, subscription link, device ID,
router configuration, IP address, log excerpt or screenshot with credentials.

The bootstrap expects a 256-bit, one-time activation code. It must not accept a
password, a long-lived shared fleet secret or an arbitrary subscription URL.
Every management tunnel and SSH credential must be unique to one device.

