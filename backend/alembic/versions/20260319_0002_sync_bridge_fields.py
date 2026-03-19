"""add sync bridge fields

Revision ID: 20260319_0002
Revises: 20260319_0001
Create Date: 2026-03-19 00:30:00
"""

from alembic import op
import sqlalchemy as sa


revision = "20260319_0002"
down_revision = "20260319_0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("tasks", sa.Column("is_all_day_due", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("tasks", sa.Column("sync_change_id", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("tasks", sa.Column("sync_pending", sa.Boolean(), nullable=False, server_default=sa.true()))
    op.add_column("tasks", sa.Column("sync_last_pushed_at", sa.DateTime(timezone=True), nullable=True))

    op.add_column("apple_reminder_mappings", sa.Column("pending_operation", sa.String(length=32), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_push_change_id", sa.Integer(), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("bridge_updated_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_ack_status", sa.String(length=32), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_error_code", sa.String(length=64), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_error_message", sa.Text(), nullable=True))
    op.add_column(
        "apple_reminder_mappings",
        sa.Column("is_deleted_on_apple", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("apple_reminder_mappings", "is_deleted_on_apple")
    op.drop_column("apple_reminder_mappings", "last_error_message")
    op.drop_column("apple_reminder_mappings", "last_error_code")
    op.drop_column("apple_reminder_mappings", "last_ack_status")
    op.drop_column("apple_reminder_mappings", "bridge_updated_at")
    op.drop_column("apple_reminder_mappings", "last_push_change_id")
    op.drop_column("apple_reminder_mappings", "pending_operation")

    op.drop_column("tasks", "sync_last_pushed_at")
    op.drop_column("tasks", "sync_pending")
    op.drop_column("tasks", "sync_change_id")
    op.drop_column("tasks", "is_all_day_due")
