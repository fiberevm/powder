# Security

Powder holds private keys and sends real orders, so reports of security problems are welcome and taken seriously.

## Reporting a problem

Please report it privately, not in a public issue: open the repository's **Security** tab and choose **Report a vulnerability**. Include what you found, how to reproduce it, and what an attacker could do with it.

## What matters most

- Anything that could expose a private key or an API key, or move them off the Mac.
- Anything that could place, change or cancel an order the user did not ask for, including through the built-in assistant or its tool server.
- Anything that lets a web tab or a token's metadata reach the wallet.

## How Powder is built to limit damage

- Private keys and API keys live only in the macOS Keychain. They are never written to settings, logs or the layout file.
- Orders and swaps are signed on the Mac and sent straight to the exchange or the landing service.
- The assistant's tool server listens on this Mac only, behind a random address that changes each launch, and has no tool that can trade.
- Release builds are signed with a Developer ID and notarized by Apple. The signing key is kept in an approval-gated environment, and each release lists SHA-256 checksums.
