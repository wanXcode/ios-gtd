from datetime import datetime

from app.services.assistant import parse_capture_input


def test_parse_tomorrow_task_defaults_to_inbox() -> None:
    parsed = parse_capture_input("提醒我明天交周报", timezone_name="UTC")

    assert parsed.intent == "create_task"
    assert parsed.summary == "交周报"
    assert parsed.bucket == "inbox"
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


def test_parse_project_like_text_routes_to_next_bucket() -> None:
    parsed = parse_capture_input("下周整理项目方案", timezone_name="UTC")

    assert parsed.summary == "整理项目方案"
    assert parsed.bucket == "next"
    assert parsed.due_at is not None
    assert parsed.needs_confirmation is True


def test_parse_empty_text_returns_low_confidence_draft() -> None:
    parsed = parse_capture_input("   ", timezone_name="UTC")

    assert parsed.summary == "Untitled task"
    assert parsed.needs_confirmation is True
    assert parsed.confidence == 0.2
