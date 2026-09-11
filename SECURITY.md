# Security policy

Security is a property of the whole ORBIT control plane, not only of the
bootstrap script. This repository is public so the protocol, validation and
local changes can be reviewed independently.

## Report privately

If you find a vulnerability or suspect a leaked secret, contact VOID support
privately. Do not open a public issue with any of the following:

- activation or refresh codes;
- subscription URLs or router configuration;
- device identifiers, management IPs or private keys;
- logs or screenshots containing credentials.

Include the affected component, a short impact description and safe reproduction
steps. Redact all live values before sharing diagnostics.

## Security invariants

The bootstrap must keep these invariants:

1. Enrollment accepts a short-lived, single-use activation code — never a
   password, arbitrary subscription URL or shared fleet secret.
2. Every management tunnel and support SSH credential is unique to one device.
3. Management connectivity is separated from the owner's VPN data plane.
4. A failed compatibility, validation or handshake check must stop the install;
   it must not silently fall back to an unprotected mode.

Changes that weaken any invariant require review in the private support channel
before release.
