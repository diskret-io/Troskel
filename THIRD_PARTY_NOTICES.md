# Third-Party Notices

This file lists third-party assets vendored or downloaded into the Troskel
project, with attribution and licence information as required by their
respective licences.

---

## EFF Long Wordlist for Passphrases

- **Source**: https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
- **Author**: Electronic Frontier Foundation
- **Licence**: Creative Commons Attribution 3.0 Unported (CC-BY 3.0)
- **Licence URL**: https://creativecommons.org/licenses/by/3.0/
- **SHA-256**: `addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e`
- **Used in**: `config/eff-large-wordlist.txt`, downloaded automatically
  by `scripts/download-wordlist.sh` during build-station setup.
- **Modifications**: None. The file is downloaded verbatim from the upstream
  URL and verified against the SHA-256 above before use.

The wordlist is used by `scripts/prepare-boot-usb.sh` to generate random
four-word diceware passphrases for the scanning-host login. It is not
committed to the repository, it is downloaded and verified at setup time
by `scripts/prepare-build-machine.sh`, which calls `download-wordlist.sh`.

**Attribution requirement**: The CC-BY 3.0 licence requires attribution when
redistributing. If you redistribute a modified or bundled version of Troskel
that includes this wordlist, you must retain this notice and credit the
Electronic Frontier Foundation as the original author.