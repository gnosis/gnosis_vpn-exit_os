# Migrate a device from hoprd v4 to v5

The image runs hoprd 5.0.3 on every device. A device that was provisioned on
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
  addresses. Both must be the ones created for this node: before it stops hoprd,
  the helper checks on the chain that the module is enabled on the new Safe and
  includes this node's address, so a pair copied from another device is refused.
- xDai on the node address. The v4 node pays for the transactions that redeem
  its tickets and close its channels; a node that ran until the update has it.
- The **old** Safe owner key, with enough xDai on that wallet to pay for the
  Safe transaction, as a keystore and a password file that only root can read
  ([how to create them](#put-the-owner-key-and-the-rpc-url-on-the-device)). The
  helper signs one Safe transaction from the old Safe with it. `hopli`-created
  Safes have threshold 1; a multi-owner Safe is refused before anything is
  stopped ([what to do then](#if-the-old-safe-has-more-than-one-owner)).
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
- The Blokli URL of the v5 network, https://blokli.piz-palu.gnosisvpn.io for
  `piz-palu-prod` (`--blokli-url`). The v4 provisioning file names the v4
  network's Blokli, which does not index the new Safe, so the helper never takes
  it for v5 and refuses to start without the option until the v5 file exists.
- Optional: the wxHOPR token address if the deployment is not the Gnosis
  production token (`--hopr-token`).

Do not reuse the old Safe and module unless you deliberately accept running v5
on the v4 module. Before it sends anything, the helper checks that the new Safe
address carries a valid checksum and is a deployed Safe on the chain the RPC
endpoint serves. When `--safe-address` is the old Safe itself, the helper closes
the channels, leaves the funds where they are and needs neither the owner
keystore nor the RPC URL. Without an RPC URL the helper cannot check the Safe
and module pair, and says so.

## What the helper does

`sudo gvpn-exit-hoprd-migrate migrate --safe-address 0xNEW \
  --module-address 0xNEWMODULE --provider-url-file FILE \
  --safe-owner-keystore FILE --safe-owner-password-file FILE \
  --blokli-url https://... [--forfeit-tickets] [--native] \
  [--v4-start-timeout SECONDS] [--v4-blokli-url https://...] \
  [--skip-v4-cleanup]`

Before it changes anything, the helper takes the OS update lock and checks the
Blokli URL, the owner key, the RPC endpoint, the new Safe and the Safe and
module pair. Then it:

1. stops `hoprd.service`;
2. decrypts the sealed v4 identity, password and API token into a private `/run`
   directory;
3. starts the bundled `/usr/libexec/gvpn-exit/hoprd-v4` on `/var/lib/hoprd` (the
   old database) and the old identity, with its API on `127.0.0.1:3101` and p2p
   on `127.0.0.1:9191`;
4. waits for the v4 node to report started (at most 90 s; `--v4-start-timeout`),
   gives it 30 s to load its channels and waits for its chain connector to
   report `Ready` (at most 120 s), requests redemption of all v4 tickets and
   watches the node until no ticket value is unredeemed (at most 300 s),
   initiates closure of every open outgoing channel, waits for the HOPR closure
   grace period (default 330 s; `--wait 0` skips the wait), finalizes the
   channels and stops the v4 node;
5. reads the old Safe's balance and sends one owner-signed Safe transaction that
   transfers the whole wxHOPR balance, and with `--native` its xDai too, to the
   new Safe, then reads the balance again and stops if anything is left;
6. writes `/etc/hoprd-v5/hoprd.env.d/10-provisioned.env` with the new Safe,
   module and Blokli URL, updates `provisioning.json` and records
   `state/hoprd-v5-migrated`; the service renders the configuration with that
   URL in both `blokli_url` fields (the top level and the PIX pool's) when it
   starts;
7. starts `hoprd.service` again, now with the v5 configuration, and watches it
   for 60 s. If hoprd does not stay up, the helper fails and says so instead of
   reporting a complete migration.

Only an outgoing channel holds this node's stake, which returns to the old Safe
when the channel closes. An incoming channel holds its counterparty's stake and
the counterparty can reopen it at any time, so the helper neither closes it nor
waits for it.

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

`--blokli-url` is required until the v5 file exists; without it the helper stops
before it changes anything. A later run without the option keeps the URL the v5
file carries. The v4 file's URL is never used for v5: it names the v4 network's
Blokli, where hoprd v5 does not find the new Safe.

The helper takes at least seven minutes: 30 s for the v4 node to load its
channels, the 330 s closure wait and the 60 s watch of hoprd, plus the time the
v4 node needs to start and to redeem its tickets. The exit is offline from step
1 until step 7. If the old Safe has no wxHOPR left, step 5 prints that and
continues.

A run in the foreground ends when the SSH session drops. To keep it running,
start it as a transient service and follow its output in the journal:

```sh
sudo systemd-run --unit=gvpn-hoprd-migrate --collect \
  gvpn-exit-hoprd-migrate migrate \
  --safe-address 0xNEWSAFE \
  --module-address 0xNEWMODULE \
  --provider-url-file /root/gnosis-rpc.url \
  --safe-owner-keystore /root/keystores/old-safe-owner \
  --safe-owner-password-file /root/old-safe-owner.password \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io
sudo journalctl -fu gvpn-hoprd-migrate
```

The run ends with `Migration complete` or with a line that starts with `ERROR`.

The helper holds the OS update lock while it runs. An update that is due in the
maintenance window waits for the helper, so the device does not reboot between
the channel closure and the fund move. A second run waits up to five minutes for
the first and then stops without changing anything.

A v4 node that has not loaded its channels yet lists none. The helper therefore
believes a listing without an open channel only while the node reports its chain
connector `Ready`, and stops otherwise; run the same command again. Stake in a
channel that stayed open does not move with the old Safe's balance. If the
amount step 5 reports is less than the node had staked, or you want to confirm
afterwards, run `close-v4-channels` again and then `move-v4-safe-funds` with the
new Safe: both are safe to repeat on a migrated device, and `configure-v5`
starts hoprd again.

A redeemed ticket pays into the old Safe, and the v5 node does not redeem v4
tickets. If ticket value is still unredeemed after the redemption wait, the
helper stops before it closes a channel and prints the value. Run the same
command again to keep redeeming, or add `--forfeit-tickets` to continue without
that value. A later `close-v4-channels` run can still redeem those tickets while
their counterparty keeps the incoming channel open.

## If a run fails or is interrupted

Run the same command again. A failed run, and one that a dropped SSH session or
a shutdown ends, stops the v4 node and removes the decrypted credentials. On a
device that has no v5 configuration yet, hoprd stays stopped; on a migrated
device the helper starts hoprd again with the configuration it had. When the v4
node ran, its log is kept at `/var/lib/gvpn-exit/state/hoprd-v4-migrate.log`
(root only) until a run succeeds.

If the last line is `hoprd.service did not stay up`, the funds have moved and
the v5 configuration is written, but hoprd exits with it. Read
`journalctl -u hoprd` and correct the Safe, the module or the Blokli URL with
`configure-v5`.

## If the v4 node does not start

The v4 node is needed to close the v4 channels and to redeem the v4 tickets, not
to run the exit. When the helper stops with `v4 hoprd did not start` or
`did not become ready`, read the kept log first, then:

- `--v4-start-timeout SECONDS` gives a node that starts slowly more than the
  default 90 s.
- `--v4-blokli-url https://...` gives the v4 node another Blokli endpoint when
  the one in the v4 provisioning file no longer answers it. The file is not
  changed, and the option does not reach the v5 configuration.
- A node address without xDai cannot send the closing transactions; fund it and
  run again.

If the v4 node cannot be started at all, bring the exit back without it:

```sh
sudo gvpn-exit-hoprd-migrate migrate \
  --safe-address 0xNEWSAFE \
  --module-address 0xNEWMODULE \
  --provider-url-file /root/gnosis-rpc.url \
  --safe-owner-keystore /root/keystores/old-safe-owner \
  --safe-owner-password-file /root/old-safe-owner.password \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io \
  --skip-v4-cleanup
```

This moves what the old Safe holds, writes the v5 configuration and starts
hoprd. Stake in a v4 channel that is still open and unredeemed v4 tickets stay
behind. To recover them when the v4 node starts again, run `close-v4-channels`
and then `move-v4-safe-funds` with the new Safe, and `configure-v5` to start
hoprd again.

## If the old Safe has more than one owner

The helper signs with one owner key and refuses a Safe whose threshold is not 1.
Use the separate steps:

1. `sudo gvpn-exit-hoprd-migrate close-v4-channels`, which needs neither the
   owner key nor the RPC URL;
2. move the old Safe's wxHOPR to the new Safe with the owners, in the Safe
   interface;
3. `sudo gvpn-exit-hoprd-migrate configure-v5 --safe-address 0xNEWSAFE
   --module-address 0xNEWMODULE --provider-url-file /root/gnosis-rpc.url
   --blokli-url https://blokli.piz-palu.gnosisvpn.io`.

## If you want separate steps

The destructive work is also available as separate commands. Each stops
`hoprd.service`; `close-v4-channels` runs the v4 cleanup node, and
`move-v4-safe-funds` uses `cast` for the owner-signed Safe transaction.
`close-v4-channels` and `move-v4-safe-funds` leave hoprd stopped, so its
strategy cannot reopen a channel before the funds move; `configure-v5` starts it
again:

```sh
sudo gvpn-exit-hoprd-migrate close-v4-channels [--wait SECONDS] [--forfeit-tickets] \
  [--v4-start-timeout SECONDS] [--v4-blokli-url https://...]
sudo gvpn-exit-hoprd-migrate move-v4-safe-funds --to 0xNEWSAFE \
  --provider-url-file /root/gnosis-rpc.url \
  --safe-owner-keystore /root/keystores/old-safe-owner \
  --safe-owner-password-file /root/old-safe-owner.password [--native]
sudo gvpn-exit-hoprd-migrate configure-v5 \
  --safe-address 0xNEWSAFE --module-address 0xNEWMODULE \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io \
  [--provider-url-file /root/gnosis-rpc.url]
```

`configure-v5` alone does not need the v4 database or credentials; it is the
step to use when only the Safe/module configuration needs correcting. Like
`migrate`, it needs `--blokli-url` until the v5 file exists and keeps the v5
file's URL when the option is left out later. With `--provider-url-file` it
checks on the chain that the module is enabled on the Safe and includes this
node before it writes anything; without it the pair is not checked and the
helper says so. It stops and starts `hoprd.service` so the running daemon picks
up the new values, and fails when hoprd does not stay up for 60 s.

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
