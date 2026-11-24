# File share permissions design

| | |
|---|---|
| **Server** | FS01 (`E:\Shares`) |
| **Share** | `\\FS01\Departments` |
| **User path** | `\\conorlab.internal\Files\Departments` (DFS), mapped as **G:** by GPO `USR - Mapped Drives` |
| **Model** | AGDLP, with access-based enumeration (ABE) on |
| **Owner** | IT |

---

## 1. Principles

1. **Permissions are only granted to Domain Local (`DL_`) groups**, never to individual users or Global groups.
2. **Users get access through their department's Global group (`GG_`)**, which is nested into the right `DL_` groups.
3. **Share permissions stay broad. NTFS permissions do the real control.** There's one place to manage access.
4. **Inheritance is removed on each department folder**, so default permissions (for example "Users: Read") don't leak in.
5. **Least privilege:** staff get Modify on their own department and the Company folder only. Read-only access to other departments is granted by request.
6. **ABE is enabled**, so users only see folders they can open.

## 2. Folder structure

```
E:\Shares                 (shared as "Departments")
├── Company               All staff
├── Finance
├── HR
├── IT
├── Operations
└── Sales
```

## 3. Groups

| Group type | Naming | Contains | Purpose |
|---|---|---|---|
| Global | `GG_<Department>` | Users | Who someone is (their department) |
| Domain Local | `DL_FS_<Folder>_RW` | Global groups | Modify access to a folder |
| Domain Local | `DL_FS_<Folder>_RO` | Global groups | Read-only access to a folder |

All groups are in `OU=Security,OU=Groups,OU=CONORLAB`.

## 4. Access matrix

| Folder | Group | NTFS permission | Members (default) |
|---|---|---|---|
| **Company** | `DL_FS_Company_RW` | Modify | All `GG_` department groups |
| **Finance** | `DL_FS_Finance_RW` | Modify | `GG_Finance` |
| | `DL_FS_Finance_RO` | Read & execute | *(empty, by request)* |
| **HR** | `DL_FS_HR_RW` | Modify | `GG_HR` |
| | `DL_FS_HR_RO` | Read & execute | *(empty, by request)* |
| **IT** | `DL_FS_IT_RW` | Modify | `GG_IT` |
| | `DL_FS_IT_RO` | Read & execute | *(empty, by request)* |
| **Operations** | `DL_FS_Operations_RW` | Modify | `GG_Operations` |
| | `DL_FS_Operations_RO` | Read & execute | *(empty, by request)* |
| **Sales** | `DL_FS_Sales_RW` | Modify | `GG_Sales` |
| | `DL_FS_Sales_RO` | Read & execute | *(empty, by request)* |

**On every department folder:** `SYSTEM`, `BUILTIN\Administrators` and `CONORLAB\Domain Admins` have Full control.

**On `E:\Shares` itself:** Authenticated Users get Read & execute on this folder only, enough to open the share and see the folders ABE allows.

### What each department sees on G:

| User's department | Visible folders | Access |
|---|---|---|
| Finance | Company, Finance | Modify |
| HR | Company, HR | Modify |
| IT | Company, IT | Modify |
| Operations | Company, Operations | Modify |
| Sales | Company, Sales | Modify |
| Domain Admins | All | Full control |

## 5. Share permissions

| Principal | Share permission |
|---|---|
| Authenticated Users | Change |
| CONORLAB\Domain Admins | Full control |

## 6. Common requests

| Request | Action |
|---|---|
| **New starter** | Add the user to their department's `GG_` group. They get G: and the right folders at next sign-in. |
| **Department move** | Remove from the old `GG_` group, add to the new one. Takes effect at next sign-in. |
| **Leaver** | Disable the account, remove all group memberships, move it to `OU=Disabled Users`. |
| **Read access to another department** (for example HR needs to read Finance) | With the folder owner's approval, add the requesting `GG_` group to `DL_FS_<Folder>_RO`. Never add individuals. |
| **New department folder** | Create the folder, remove inheritance, create `DL_FS_<Folder>_RW` / `_RO`, grant NTFS permissions, nest the `GG_` group. |

> Group changes apply at the user's **next sign-in**, because group membership is part of the sign-in token. Ask users to sign out and back in after a change.

## 7. Review

- Review membership of every `DL_FS_*` group **quarterly**, with each department head confirming who has access.
- Check for permissions granted directly to users (which shouldn't exist):
  ```powershell
  Get-ChildItem E:\Shares -Directory | ForEach-Object { icacls $_.FullName }
  ```
- Export current group membership for the review:
  ```powershell
  Get-ADGroup -Filter "Name -like 'DL_FS_*'" | ForEach-Object {
      [pscustomobject]@{ Group = $_.Name; Members = (Get-ADGroupMember $_ | Select-Object -ExpandProperty Name) -join ', ' }
  }
  ```
