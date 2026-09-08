# Apple authentication compatibility testing

This experimental build keeps Standard authentication as the default and adds
an iLoader Compatibility mode. It adapts selected authentication requests to
iLoader's implementation; it does not guarantee a fix for Apple's HTTP 503
responses. A successful CI build cannot establish that Apple accepts a real
account's authentication requests.

The compatibility profile follows isideload revision
`3d42025ecac97a2548d5b88aefc8028307e369c1`: its client identity and GrandSlam
headers, string-valued CPD flags, reduced CPD fields, and service URL lookup.
The `complete` request also asks to close its HTTP connection. Actual connection
handling remains the responsibility of URLSession and the negotiated HTTP
protocol. Existing SRP proof validation and 2FA challenge handling remain in
SideSign. This is a comparison of request profiles, not a port of the Rust library.

The selected profile applies to sign-in and all subsequent developer operations,
including team lookup, certificates, devices, and provisioning profiles. These
requests retain their existing session tokens, Anisette data, and API-specific
content types while using the same client identity as sign-in.
An unavailable or invalid service lookup fails visibly in compatibility mode;
it does not silently switch back to the Standard endpoint.

## Install and identify the build

1. Download the IPA artifact from the fork's test workflow for the intended
   branch and commit.
2. Use iLoader to sign and install the IPA on the device. The CI artifact still
   needs device-specific signing; no Apple account credentials belong in CI.
3. Open the installed SideStore and verify the version and commit identifier
   in its startup console log against the build you downloaded. Check the
   actual running instance, especially if more than one SideStore is installed.
4. Enable LocalDevVPN when testing the complete sign-in and installation flow.
   Its local device tunnel is separate from the Internet connection used by
   Apple's authentication service.

## Compare the authentication modes

1. Keep the Apple account, network connection, proxy configuration, and Anisette
   source the same for both attempts.
2. Open Settings > User Customizations > Authentication and choose Standard.
3. If an account is already signed in, sign out before the attempt so a saved
   Xcode token cannot bypass password authentication. Use the existing options
   to preserve the signing certificate and Anisette data.
4. Sign in once and record the result, including the authentication stage and
   HTTP status if an error occurs.
5. Choose iLoader Compatibility in the same Authentication menu and confirm
   Change and Sign Out. This clears the saved login session while preserving
   the signing certificate and provisioned Anisette data. No restart is needed
   for an authentication mode change.
6. Sign in again and compare the result. Switching back to Standard uses the
   same confirmation and sign-out behavior.

Authentication mode and Anisette source are independent settings. To test a
remote V3 Anisette server, disable Settings > User Customizations > On-Device
Anisette, follow its existing restart prompt, and select the intended server
under Anisette Servers. That source change clears provisioned Anisette data;
changing authentication mode does not. Compare the authentication modes with
one Anisette source before changing the source for a separate comparison.

## Collect useful diagnostics

Open Settings > View Error Log > Console after the attempt. Authentication mode,
request stage, HTTP status, response type, and response size diagnostics are
visible without enabling verbose logging. Keep the build identifier and these
diagnostics together so results from different installations are distinguishable.

Filter for `[AppleAuth]`. Each request has a flow identifier, mode, and stage
(`lookup`, `init`, `complete`, `apptokens`, `viewDeveloper`, `listTeams`, a
`developer-*` stage, or a `2fa-*` stage).
HTTP response lines include status, a classified content type/format, byte count,
and elapsed milliseconds. A 503 HTML page is reported with its stage instead of
being treated as a normal plist response. Structured Apple errors retain the
existing password and verification-code error handling. No automatic 503 retry
is performed.

Do not include passwords, verification codes, authentication tokens, raw request
or response bodies, or Anisette secrets in shared logs. Existing logs elsewhere
in the app may contain account or device identifiers, especially with verbose
logging enabled; redact those before sharing an export. A mode comparison is
evidence about those two attempts, not proof that Apple or every account will
behave identically on future requests.
