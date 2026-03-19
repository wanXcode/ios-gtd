from app.services.assistant import parse_capture_input
from app.services.bucket_policy import (
    apple_reminders_list_to_bucket,
    bucket_to_apple_reminders_list,
    canonicalize_bucket,
)


def test_parse_tomorrow_task_defaults_to_next_action() -> None:
    parsed = parse_capture_input("提醒我明天交周报", timezone_name="UTC")

    assert parsed.intent == "create_task"
    assert parsed.summary == "交周报"
    assert parsed.bucket == "next"
    assert parsed.needs_confirmation is False
    assert parsed.due_at is not None
    assert parsed.due_at.hour == 18
    assert parsed.remind_at is None
    assert parsed.confidence >= 0.7


def test_parse_tomorrow_evening_specific_time_sets_reminder() -> None:
    parsed = parse_capture_input("明晚8点给妈妈打电话", timezone_name="UTC")

    assert parsed.summary == "给妈妈打电话"
    assert parsed.time_expression == "明晚"
    assert parsed.due_at is not None
    assert parsed.remind_at is not None
    assert parsed.due_at.hour == 20
    assert parsed.remind_at == parsed.due_at.replace(hour=18)
    assert parsed.needs_confirmation is False


def test_parse_someday_keyword_routes_to_someday_bucket() -> None:
    parsed = parse_capture_input("以后再说 学德语", timezone_name="UTC")

    assert parsed.summary == "学德语"
    assert parsed.bucket == "someday"
    assert parsed.needs_confirmation is False


def test_parse_waiting_for_routes_to_waiting_bucket() -> None:
    parsed = parse_capture_input("等张三回复合同", timezone_name="UTC")

    assert parsed.summary == "等张三回复合同"
    assert parsed.bucket == "waiting"
    assert parsed.due_at is None


def test_parse_project_intent_routes_to_project_bucket() -> None:
    parsed = parse_capture_input("项目：Q2 产品升级", timezone_name="UTC")

    assert parsed.intent == "create_project"
    assert parsed.project_name == "Q2 产品升级"
    assert parsed.bucket == "project"


def test_parse_project_like_text_with_time_stays_next_action() -> None:
    parsed = parse_capture_input("下周整理项目方案", timezone_name="UTC")

    assert parsed.summary == "整理项目方案"
    assert parsed.bucket == "next"
    assert parsed.due_at is not None
    assert parsed.needs_confirmation is True
    assert parsed.error_code == "ambiguous_time"
    assert any("项目" in question for question in parsed.questions)
    assert any("下周" in question for question in parsed.questions)
<<<<<<< HEAD


def test_bucket_policy_supports_aliases_and_exact_apple_list_names() -> None:
    assert canonicalize_bucket("next_action") == "next"
    assert canonicalize_bucket("waiting_for") == "waiting"
    assert canonicalize_bucket("maybe") == "someday"
    assert bucket_to_apple_reminders_list("inbox") == "收集箱 @Inbox"
    assert bucket_to_apple_reminders_list("next_action") == "下一步行动@NextAction"
    assert apple_reminders_list_to_bucket("等待@Waiting For") == "waiting"
    assert apple_reminders_list_to_bucket("可能的事 @Maybe") == "someday"
=======
>>>>>>> 72b14cf (feat(backend): add capture follow-up questions)


def test_bucket_policy_supports_aliases_and_exact_apple_list_names() -> None:
    assert canonicalize_bucket("next_action") == "next"
    assert canonicalize_bucket("waiting_for") == "waiting"
    assert canonicalize_bucket("maybe") == "someday"
    assert bucket_to_apple_reminders_list("inbox") == "收集箱 @Inbox"
    assert bucket_to_apple_reminders_list("next_action") == "下一步行动@NextAction"
    assert apple_reminders_list_to_bucket("等待@Waiting For") == "waiting"
    assert apple_reminders_list_to_bucket("可能的事 @Maybe") == "someday"


def test_parse_empty_text_returns_low_confidence_draft() -> None:
    parsed = parse_capture_input("   ", timezone_name="UTC")

    assert parsed.summary == "Untitled task"
    assert parsed.needs_confirmation is True
    assert parsed.confidence == 0.2
    assert parsed.error_code == "empty_title"
    assert parsed.questions == ["你想记的具体事项是什么？"]


def test_parse_ambiguous_time_returns_follow_up_question() -> None:
    parsed = parse_capture_input("晚点提醒我看下邮箱", timezone_name="UTC")

    assert parsed.needs_confirmation is True
    assert parsed.due_at is None
    assert parsed.error_code == "needs_confirmation"
    assert parsed.questions == ["你希望我什么时候提醒你？给我一个更具体的时间吧。"]
