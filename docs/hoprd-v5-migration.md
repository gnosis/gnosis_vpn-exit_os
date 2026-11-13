# Migrate a device from hoprd v4 to v5

The image runs hoprd 5.0.2 on every device. A device that was provisioned on
hoprd v4 keeps its old database and its sealed identity, so it still boots after
the update, but its v4 channels and its old Safe need one manual cleanup before
v5 uses the new Safe.

The v5 service stays stopped until
`/etc/hoprd-v5/hoprd.env.d/10-provisioned.env` exists, so its strategies cannot
open channels or deposit PIX from the old Safe before the funds move. The
required boot check treats that as a pending migration rather than a red boot,
so the device updates and boots green, and the exit starts serving when the
helper has written the v5 file.

## Before you start

- The update to the v5 image has been applied and the device is reachable (LAN
  SSH or the support tunnel).
- The old node address from `sudo gvpn-exit-provision status` (or
  `provisioning.json`).
- A **new** Safe and node module on `piz-palu-prod`, created with `hopli`
  `safe-module create` using that node address and the Safe owner as admin. See
  the upstream migration guide for the command; the device only consumes the two
  addresses.
- The **old** Safe owner key, with enough xDai on that wallet to pay for the
  Safe transaction, as a keystore and a password file that only root can read
  ([how to create them](#put-the-owner-key-and-the-rpc-url-on-the-device)). The
  helper signs one Safe transaction from the old Safe with it. `hopli`-created
  Safes have threshold 1; a multi-owner Safe is refused.
- A Gnosis Chain HTTPS RPC URL, in a file that only root can read
  ([how to create it](#put-the-owner-key-and-the-rpc-url-on-the-device)).
  `hoprd` uses Blokli, but the Safe transaction goes through `cast`, so the
  helper needs an RPC endpoint.
- The new Safe address in EIP-55 checksum form (mixed upper and lower case), as
  `hopli` and the Safe interface print it. The helper refuses an all-lowercase
  address or one whose checksum is wrong, because a mistyped digit would send
  the funds to an address nobody controls. `cast to-check-sum-address 0x...`
  prints the checksum form of an address; compare its output with the source you
  copied the address from.
- Optional: the wxHOPR token address if the deployment is not the Gnosis
  production token (`--hopr-token`).

Do not reuse the old Safe and module unless you deliberately accept running v5
on the v4 module. Before it sends anything, the helper checks that the new Safe
address carries a valid checksum and is a deployed Safe on the chain the RPC
endpoint serves. When `--safe-address` is the old Safe itself, the helper closes
the channels, leaves the funds where they are and needs neither the owner
keystore nor the RPC URL.

## What the helper does

`sudo gvpn-exit-hoprd-migrate migrate --safe-address 0xNEW \
  --module-address 0xNEWMODULE --provider-url-file FILE \
  --safe-owner-keystore FILE --safe-owner-password-file FILE \
  [--blokli-url https://...] [--forfeit-tickets] [--native]`

1. stops `hoprd.service`;
2. decrypts the sealed v4 identity, password and API token into a private `/run`
   directory;
3. starts the bundled `/usr/libexec/gvpn-exit/hoprd-v4` on `/var/lib/hoprd` (the
   old database) and the old identity, with its API on `127.0.0.1:3101` and p2p
   on `127.0.0.1:9191`;
4. waits for the v4 node's chain connector to report `Ready` (at most 120 s),
   requests redemption of all v4 tickets and watches the node until no ticket
   value is unredeemed (at most 300 s), closes every open outgoing and incoming
   channel, waits for the HOPR closure grace period (default 330 s; `--wait 0`
   skips the wait) and finalizes the channels;
5. reads the old Safe's balance and sends one owner-signed Safe transaction that
   transfers the whole wxHOPR balance, and with `--native` its xDai too, to the
   new Safe, then reads the balance again and stops if anything is left;
6. writes `/etc/hoprd-v5/hoprd.env.d/10-provisioned.env` with the new Safe,
   module and Blokli URL, updates `provisioning.json` and records
   `state/hoprd-v5-migrated`; the service renders the configuration with that
   URL in both `blokli_url` fields (the top level and the PIX pool's) when it
   starts;
7. starts `hoprd.service` again, now with the v5 configuration.

The old identity credential (`creds/hopr.id.cred`) and the old provisioning file
(`/etc/hoprd/hoprd.env.d/10-provisioned.env`) are never modified. The v4 cleanup
node does update the old database (`/var/lib/hoprd`) as it redeems tickets and
closes channels. The v5 service uses a copy of the identity under
`/run/hoprd/hopr-v5.id`, so a v5 start cannot overwrite the v4 identity the
helper still needs.

Every step is safe to repeat. If the helper fails halfway, run the same command
again; already-closed channels are skipped and a zero old-Safe balance is
reported, not withdrawn twice.

## Put the owner key and the RPC URL on the device

The helper signs from a keystore and does not accept a raw private key: `cast`
takes a raw key only as a command-line argument, and every local process can
read the arguments of a running command. Create the keystore on the device;
`cast` asks for the key and for a new password on the terminal:

```sh
sudo cast wallet import old-safe-owner --interactive --keystore-dir /root/keystores
sudo sh -c 'umask 077; cat > /root/old-safe-owner.password'   # type the password, then Ctrl-D
```

An RPC URL usually carries an API key, and the options of a running command are
readable by every local process, so the helper reads the URL from the first line
of a file and hands it to `cast` in its environment:

```sh
sudo sh -c 'umask 077; cat > /root/gnosis-rpc.url'   # paste the URL, Enter, then Ctrl-D
```

`--provider-url URL` takes the URL as an option instead; use it only for an
endpoint without a key in its URL.

Delete all three files when the migration is complete.

## Run it

```sh
sudo gvpn-exit-hoprd-migrate status
sudo gvpn-exit-hoprd-migrate migrate \
  --safe-address 0xNEWSAFE \
  --module-address 0xNEWMODULE \
  --provider-url-file /root/gnosis-rpc.url \
  --safe-owner-keystore /root/keystores/old-safe-owner \
  --safe-owner-password-file /root/old-safe-owner.password \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io
```

`--blokli-url` defaults to the URL the device already runs with (the v5 file on
a rerun, else the old v4 file), so pass it only when you want to change it.

The helper takes about six minutes with the default closure wait, plus the time
the node needs to redeem its tickets. The exit is offline from step 1 until
step 7. If the old Safe has no wxHOPR left, step 5 prints that and continues.

A v4 node that has not loaded its channels yet lists none. The helper therefore
believes a listing without an open channel only while the node reports its chain
connector `Ready`, and stops otherwise; run the same command again. Stake in a
channel that stayed open does not move with the old Safe's balance. If the
amount step 5 reports is less than the node had staked, or you want to confirm
afterwards, run `close-v4-channels` again and then `move-v4-safe-funds` with the
new Safe: both are safe to repeat on a migrated device, and `configure-v5`
starts hoprd again.

Closing an incoming channel voids the tickets still unredeemed in it. If ticket
value is still unredeemed after the redemption wait, the helper stops before it
closes a channel and prints the value. Run the same command again to keep
redeeming, or add `--forfeit-tickets` to close the channels and give that value
up.

## If you want separate steps

The destructive work is also available as separate commands. Each stops
`hoprd.service`; `close-v4-channels` runs the v4 cleanup node, and
`move-v4-safe-funds` uses `cast` for the owner-signed Safe transaction.
`close-v4-channels` and `move-v4-safe-funds` leave hoprd stopped, so its
strategy cannot reopen a channel before the funds move; `configure-v5` starts it
again:

```sh
sudo gvpn-exit-hoprd-migrate close-v4-channels [--wait SECONDS] [--forfeit-tickets]
sudo gvpn-exit-hoprd-migrate move-v4-safe-funds --to 0xNEWSAFE \
  --provider-url-file /root/gnosis-rpc.url \
  --safe-owner-keystore /root/keystores/old-safe-owner \
  --safe-owner-password-file /root/old-safe-owner.password [--native]
sudo gvpn-exit-hoprd-migrate configure-v5 \
  --safe-address 0xNEWSAFE --module-address 0xNEWMODULE [--blokli-url https://...]
```

`configure-v5` alone does not need the v4 database or credentials; it is the
step to use when only the Safe/module configuration needs correcting. It stops
and starts `hoprd.service` so the running daemon picks up the new values.

## Check the result

```sh
sudo gvpn-exit-status
sudo systemctl status hoprd
journalctl -u hoprd -f
sudo hopli safe-module check-safe --provider-url <RPC> --safe-address 0xNEWSAFE
```

`hopli` takes the RPC URL only as an option, where every local process can read
it while the command runs. Use an endpoint without a key for this check, or run
it on a machine that only you use.

The diagnostic must report the new Safe and module in the provisioning record
and hoprd healthy once the new Safe is funded (PIX still needs wxHOPR for
deposits). The node address stays the same, so it must already be on the
GnosisVPN client destination list.

## Rollback

Rolling the image back to the last v4 deployment restores the v4 database from
the snapshot `update-apply.sh` took before the update and starts v4 on it. The
old Safe is empty after the migration and its channels are closed, so that
device no longer earns until it is migrated forward again. The v5 data and its
snapshot are left in place.
