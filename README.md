# autowin

AutoWin is my working project for automating Windows deployment and initial setup.

It is meant to help after preparing a reference Windows image and running `Sysprep`, so the system can go through the main setup steps automatically:
- enter the PC name
- rename the computer
- install updates
- join the domain
- apply group policies
- manually clean temporary deployment files and autologon traces at the end

## What the project does

The workflow is simple:

1. A reference Windows image is prepared
2. `Deploy` and `unattend.xml` are copied into the system
3. `Sysprep` is started
4. After first boot, Windows automatically starts the bootstrap logic
5. The user enters the asset ID
6. The system then goes through the main setup stages

## What asset ID means

**Asset ID is the computer name** that the machine should receive in your environment and under which it should appear in the domain.

So this should not be random text.  
It should be the final hostname of the machine based on your internal naming format.

Examples:
- `u1-1870`
- `u1-0101x`

## What is inside the repository

The repository contains two versions:
- `autowin10`
- `autowin11`

Each version contains:
- `unattend.xml`
- `command for start.txt`
- `Deploy` folder

Inside `Deploy`:
- `bootstrap.ps1`
- `deploy-system.ps1`
- `status.ps1`
- `config.json`

## Where to start

First, I recommend preparing a clean reference image for the Windows version you need.

That means:
- install clean Windows
- install the software you actually need
- bring the system to the state you want before deployment
- then prepare `Deploy`, `unattend.xml`, and only after that run `Sysprep`

## Important warning

While preparing the reference image, do not install Windows updates, language packs, or other Microsoft-related components unless you really need them before `Sysprep`.

This can cause `Sysprep` to fail or behave incorrectly.

The project is built around this idea:
- **before Sysprep**, the image should stay as clean as possible
- **after first boot**, AutoWin handles the rest of the setup

## How to start it

Each version includes a file called `command for start.txt`.

The command used is:

`C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\Windows\System32\Sysprep\unattend.xml`

Before running it, you need to:
1. copy `unattend.xml` into the Sysprep folder
2. copy the `Deploy` folder into `C:\Deploy`
3. fill in `config.json`
4. check local accounts and passwords
5. only then run `Sysprep`

## What must be changed before use

Before using this project, you need to adapt it to your own environment.

### 1. Domain settings
In `Deploy/config.json`, you need to enter your own values:
- `Domain`
- `JoinUser`
- `JoinPass`
- `OUPath` — if you want the machine to be placed directly into a specific OU

If you do not fill this in, domain join will not work.

### 2. Passwords
You must review and replace all passwords and placeholders with your own values.

Make sure to check:
- local accounts in `unattend.xml`
- autologon settings
- the domain join password in `config.json`
- any first-logon commands that may contain passwords

### 3. Local accounts
In the current Windows 11 version, two local accounts are created:
- `Admin`
- `User`

If you do not need them, you can either:
- remove them from `unattend.xml` before running `Sysprep`
- or disable / delete them after installation

In the Windows 10 version, only this account is created:
- `Admin`

## How the workflow works

After first boot:
- bootstrap starts
- the script asks for the asset ID
- the asset ID is saved and used as the computer name
- the system renames the PC
- installs updates
- joins the domain
- runs `gpupdate /force`
- shows deployment progress through `status.ps1`
- writes logs into `C:\Deploy\Logs\deploy.log`

If something goes wrong, the first place to check is:
`C:\Deploy\Logs\deploy.log`

## Important note about cleanup

Do not assume that everything will always be removed automatically.

**After deployment is finished, you should manually check and remove:**

### 1. Autologon traces in Winlogon
Open the registry and check:

`HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`

After installation and deployment are finished, remove or reset any values related to autologon if they are still present.

The main values to check are:
- `AutoAdminLogon`
- `DefaultUserName`
- `DefaultPassword`
- `DefaultDomainName`

If you leave them there, the machine may keep unnecessary automatic logon data.

### 2. The `C:\Deploy` folder
After installation is complete, I recommend manually deleting:
- `C:\Deploy`
- temporary deployment files
- logs and helper files if they are no longer needed

In other words, final cleanup should always be checked manually instead of relying only on the script.

## Practical purpose of the project

AutoWin exists so you do not have to repeat the same manual steps on every new PC.

It helps automate:
- computer renaming
- Windows updates
- domain join
- group policy application
- initial post-install setup

## Final note

This is not a universal enterprise product.  
It is my practical working project built around real system administration tasks.

Its purpose is simple:
- prepare Windows machines faster
- reduce repetitive manual work
- lower the chance of forgetting something
- bring the system to the required state after installation

But before using it, you still need to:
- enter your own domain
- enter your own accounts
- replace passwords
- review local users
- manually remove autologon traces and the `Deploy` folder after installation
