from __future__ import annotations

from dataclasses import dataclass

from app.models.enums import TaskBucket


@dataclass(frozen=True)
class BucketPolicy:
    apple_reminders_list_name: str
    aliases: tuple[str, ...] = ()


BUCKET_POLICY: dict[str, BucketPolicy] = {
    TaskBucket.INBOX.value: BucketPolicy(
        apple_reminders_list_name="收集箱 @Inbox",
        aliases=(TaskBucket.INBOX.value,),
    ),
    TaskBucket.NEXT.value: BucketPolicy(
        apple_reminders_list_name="下一步行动@NextAction",
        aliases=(TaskBucket.NEXT.value, "next_action"),
    ),
    TaskBucket.WAITING.value: BucketPolicy(
        apple_reminders_list_name="等待@Waiting For",
        aliases=(TaskBucket.WAITING.value, "waiting_for"),
    ),
    TaskBucket.SOMEDAY.value: BucketPolicy(
        apple_reminders_list_name="可能的事 @Maybe",
        aliases=(TaskBucket.SOMEDAY.value, "maybe"),
    ),
    TaskBucket.PROJECT.value: BucketPolicy(
        apple_reminders_list_name="项目 @Project",
        aliases=(TaskBucket.PROJECT.value,),
    ),
    TaskBucket.DONE.value: BucketPolicy(
        apple_reminders_list_name="下一步行动@NextAction",
        aliases=(TaskBucket.DONE.value,),
    ),
}


BUCKET_ALIAS_TO_CANONICAL: dict[str, str] = {
    alias: canonical
    for canonical, policy in BUCKET_POLICY.items()
    for alias in policy.aliases
}


APPLE_REMINDERS_LIST_TO_BUCKET: dict[str, str] = {
    policy.apple_reminders_list_name: canonical for canonical, policy in BUCKET_POLICY.items() if canonical != TaskBucket.DONE.value
}


def canonicalize_bucket(bucket: str | None, *, default: str = TaskBucket.INBOX.value) -> str:
    if not bucket:
        return default
    normalized = bucket.strip().lower()
    return BUCKET_ALIAS_TO_CANONICAL.get(normalized, default)


def bucket_to_apple_reminders_list(bucket: str | None, *, default: str = TaskBucket.INBOX.value) -> str:
    canonical = canonicalize_bucket(bucket, default=default)
    return BUCKET_POLICY[canonical].apple_reminders_list_name


def apple_reminders_list_to_bucket(list_name: str | None, *, default: str = TaskBucket.INBOX.value) -> str:
    if not list_name:
        return default
    return APPLE_REMINDERS_LIST_TO_BUCKET.get(list_name.strip(), default)
