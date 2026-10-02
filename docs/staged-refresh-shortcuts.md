# Refresh profiles in two Shortcuts actions

This branch starts from upstream develop `0dd743f75afc358b0ba4a002feb5f19474492371`.
It adds two actions and returns recoverable errors as values from the existing
**Refresh All Apps** action. Install IPA retains its existing behavior.

## Actions and results

- **Prepare All App Refresh Profiles** downloads profiles for the same eligible
  applications as Refresh All Apps, including required extension profiles. It
  saves a batch on this device and returns its **Batch Identifier**. Preparing a
  profile does not change the displayed refresh or expiration dates.
- **Refresh Apps with Prepared Profiles** takes that identifier and installs the
  saved profiles through the configured device connection. It updates each app's
  dates only after all of that app's profiles have been installed successfully.

Both actions return a **Refresh Result** with Success, Status, Message, Batch
Identifier, Successful Apps, Failed Apps and App Results. Status is `success`,
`partial`, `failure` or `no_apps`. `partial` means some apps succeeded and others
failed; Success is false for both `partial` and `failure`. A partial preparation
may still provide a batch containing the successfully prepared apps.

These two actions neither require Wi-Fi nor consult the Cellular Refresh toggle.
They do not change cellular data or VPN state and do not launch other shortcuts.
Preparation needs Internet access and an already configured account. Applying
needs a valid device connection and pairing; it does not request new profiles
from Apple. Complete initial login/device registration in SideStore first.

The existing **Refresh All Apps** action also returns a Refresh Result when an
operation fails, allowing subsequent cleanup actions to run. It retains its
existing network checks and Cellular Refresh behavior. Use the two new actions
when the outer shortcut is intended to own network changes.

## Example shortcut

1. Record the cellular/VPN state that you intend to restore.
2. While Internet access is available, run **Prepare All App Refresh Profiles**.
3. If its Batch Identifier is not empty, enable LocalDevVPN, turn cellular data
   off if needed for your configuration, and run **Refresh Apps with Prepared
   Profiles**. Set its Batch Identifier to that property of the preparation
   result, not to the result's message or a fixed identifier from another run.
4. Restore cellular/VPN state after that conditional block.
5. Inspect the returned Status/App Results and show any failures after cleanup.

Do not use Stop This Shortcut on a failed result before restoring the network.
An empty or invalid batch identifier returns a failure result rather than opening
a batch picker or throwing an execution error.

## Batch lifetime and recovery

Batches are local to this installation, bound to the account, team and device,
and valid for at most 24 hours from creation; retrying never extends that period.
Unused and unfinished batches are removed at the next app launch or prepare/apply
action after expiration. iOS does not guarantee execution at the expiration time
when the app is not running. Successfully applied apps immediately drop their
stored profile bytes; only a small completion record remains until expiration,
so replay can report an already completed app without writing it again.
Profiles must still be valid and match the
installed apps and signing certificates at application time. A removed,
reinstalled or changed app may need a new batch. Expired/revoked certificates or
other cases requiring a full re-sign must be handled in the app first.

The result lists individual app failures. Retrying a batch skips apps already
recorded as successfully applied and retries unfinished apps. Profile writes on
the phone are not transactional: an app with several extensions can have some
profiles installed before another fails. Its dates are not advanced until all
required writes succeed. A crash between device writes and saving the completion
record can cause a harmless repeated installation on retry.

## Background execution limits

The actions normally run without opening SideStore. Like Refresh All Apps, a
long-running action may ask to continue in the foreground. Catchable errors are
returned as values, but user cancellation, process termination, an iOS execution
deadline or failure of an outer Shortcuts action can prevent subsequent cleanup.
No app can guarantee that cleanup runs after the operating system kills it.

Remote Pairing can still reject a device that has not been unlocked recently
(`com.apple.dt.RemotePairingError`, code 1016). Splitting network stages does not
bypass that system restriction. Test while unlocked before testing automation.

## Validation

The test workflow runs focused persistence/outcome/concurrency checks, builds the
entire iOS app, and validates IPA versions, architecture and entitlements. Device
validation still needs: preparation on cellular, apply with cellular disabled and
Cellular Refresh turned off, failure followed by VPN cleanup, partial batch retry,
and a process restart between preparing and applying.
