# Document permissions

Every operation on a document checks who is asking. A refused operation
raises `PermissionDenied`; an unknown document id raises `NotFound`.

- A suspended user may do nothing: not create, read, edit, archive, delete
  or share.
- An admin (role `admin`) of the document's organization may do everything to
  it, archived or not. An admin of another organization has no special rights.
- The owner may read, edit, archive, delete and share their document.
- A document can be shared with a user at level `view` (read) or `edit` (read
  and edit). Only the owner or an org admin may share or unshare, only with
  users in the document's organization, and only at those two levels. Users
  it was shared with may not share it further or delete it.
- A document marked `org_visible` may be read by any user of the same
  organization who has the `viewer` role.
- An archived document can still be read by everyone who could read it
  before. Only an org admin may edit or share it. The owner and org admins may
  still delete it.
- `list_readable(user)` returns the documents the user may read, sorted by id.
