## Contributing to ReProvision Reborn
Hey there! Thanks for being interested in contributing to this project. There are specific guidelines that must be followed before contributions to the project are accepted, which are showcased below.

## Submitting issues
Issues for reproducible ReProvision Reborn bugs are welcome, but duplicates, unsupported environments, and reports without enough device or jailbreak details may be closed or marked as needing more information.

Bug reports should include the exact iOS version, device model, jailbreak environment, ReProvision Reborn version or commit, Apple account type, exact error text, and minimal reproduction steps.

Do not include Apple ID passwords, app-specific passwords, session tokens, provisioning secrets, or other private account data in public issues.

Security-sensitive issues should not be reported publicly. Follow `SECURITY.md` for private reporting guidance.

## Submitting pull requests
Pull requests and the process of accepting them is very loose, but typically, you'd want to follow the steps below
1. Make sure that your pull request is not a duplicate of another
2. Make sure that the feature you're adding is not already a feature to ReProvision Reborn
3. Test your own build of ReProvision Reborn with the changes you made on a **physical** device
4. If your pull request fixes an issue or satisfies a feature request, associate the ticket that the pull request satisfies by referencing ticket numbers where practical
5. Update ``README.md`` or other documentation when the change affects users, compatibility, security-sensitive behavior, or build steps
6. For changes touching Apple account authentication, Keychain credentials, provisioning APIs, signing, URL scheme IPA installation, or the background daemon, describe what workflow was tested
