"""Who may do what to a document."""
ADMIN = "admin"
VIEWER = "viewer"
VIEW = "view"
EDIT = "edit"
SHARE_LEVELS = (VIEW, EDIT)


def is_org_admin(user, doc):
    return ADMIN in user.roles and user.org == doc.org


def is_owner(user, doc):
    return user.id == doc.owner_id


def share_level(user, doc):
    return doc.shares.get(user.id)


def can_read(user, doc):
    if user.suspended:
        return False
    if is_org_admin(user, doc) or is_owner(user, doc):
        return True
    if share_level(user, doc) in SHARE_LEVELS:
        return True
    return doc.org_visible and user.org == doc.org and VIEWER in user.roles


def can_edit(user, doc):
    if user.suspended:
        return False
    if is_org_admin(user, doc):
        return True
    if doc.archived:
        return False
    return is_owner(user, doc) or share_level(user, doc) == EDIT


def can_delete(user, doc):
    if user.suspended:
        return False
    return is_org_admin(user, doc) or is_owner(user, doc)


def can_share(user, doc, target, level):
    if user.suspended:
        return False
    if level not in SHARE_LEVELS:
        return False
    if target.org != doc.org:
        return False
    if is_org_admin(user, doc):
        return True
    return is_owner(user, doc) and not doc.archived
