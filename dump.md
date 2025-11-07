dsaa@dsaa:~$ curl -fsSL https://bun.sh/install | bash                error: unzip is required to install bun                              dsaa@dsaa:~$ unzip
Command 'unzip' not found, but can be installed with:                apt install unzip
Please ask your administrator.                                       dsaa@dsaa:~$ apt install unzip
E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), are you root?
dsaa@dsaa:~$ whoami                                                  dsaa
dsaa@dsaa:~$ sudo su                                                 root@dsaa:/home/dsaa# sudo apt install unzip
Reading package lists... Done                                        Building dependency tree... Done
Reading state information... Done                                    Suggested packages:
  zip                                                                The following NEW packages will be installed:
  unzip                                                              0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.
Need to get 174 kB of archives.                                      After this operation, 384 kB of additional disk space will be used.
Get:1 http://kebo.pens.ac.id/ubuntu noble-updates/main amd64 unzip amd64 6.0-28ubuntu4.1 [174 kB]
Fetched 174 kB in 1s (131 kB/s)                                      Selecting previously unselected package unzip.
(Reading database ... 106424 files and directories currently installed.)
Preparing to unpack .../unzip_6.0-28ubuntu4.1_amd64.deb ...
Unpacking unzip (6.0-28ubuntu4.1) ...
Setting up unzip (6.0-28ubuntu4.1) ...
Processing triggers for man-db (2.12.0-4build2) ...
Scanning processes...
Scanning linux images...
                                                                     Running kernel seems to be up-to-date.

No services need to be restarted.

No containers need to be restarted.

No user sessions are running outdated binaries.

No VM guests are running outdated hypervisor (qemu) binaries on this
 host.
root@dsaa:/home/dsaa#

apt install htop
apt install tmux
curl -fsSL https://bun.sh/install | bash
source /root/.bashrc
apt install nodejs
bun i -g @anthropic-ai/claude-code
apt install gh
root@dsaa:/home/dsaa# gh auth login
? What account do you want to log into? GitHub.com                   ? What is your preferred protocol for Git operations on this host? HTTPS                                                                  ? Authenticate Git with your GitHub credentials? Yes                 ? How would you like to authenticate GitHub CLI? Paste an authentication token
Tip: you can generate a Personal Access Token here https://github.com/settings/tokens
The minimum required scopes are 'repo', 'read:org', 'workflow'.
? Paste your authentication token:
*******

Tip: you can generate a Personal Access Token here https://github.com/settings/tokens
The minimum required scopes are 'repo', 'read:org', 'workflow'.
? Paste your authentication token: **********************************- gh config set -h github.com git_protocol https
✓ Configured git protocol
! Authentication credentials saved in plain text
✓ Logged in as dsaatools
root@dsaa:/home/dsaa# curl -fsSL https://app.factory.ai/cli | sh
Downloading Factory CLI v0.22.12 for linux-x64
Fetching and verifying checksum
Checksum verification passed
Downloading ripgrep for linux-x64
Fetching and verifying ripgrep checksum
Ripgrep checksum verification passed
Factory CLI v0.22.12 installed successfully to /root/.local/bin/droid
Ripgrep installed successfully to /root/.factory/bin/rg
Checking PATH configuration...
PATH configuration required
Add /root/.local/bin to your PATH:
  echo 'export PATH=/root/.local/bin:$PATH' >> ~/.bashrc
  source ~/.bashrc
Then run 'droid' to get started!
root@dsaa:/home/dsaa# echo 'export PATH=/root/.local/bin:$PATH' >> ~/.bashrc
  source ~/.bashrc
root@dsaa:/home/dsaa#
export FACTORY_API_KEY=******

Just add the custom_models in the ~/.factory/config.json

In our case, the custom_models should look like this

{
  "custom_models": [
    {
      "model_display_name": "GLM 4.6 Coding Plan",
      "model": "glm-4.6",
      "base_url": "https://api.z.ai/api/anthropic",
      "api_key": "YOUR_ZAI_API_KEY",
      "provider": "zai"
    }
  ]
}
Once you’ve added the config, you can now use the /model command in the droid CLI to select that model.



root@dsaa:/home/dsaa# mkdir code
root@dsaa:/home/dsaa# cd code
root@dsaa:/home/dsaa/code#
