"""add sync delivery ledger

Revision ID: 20260319_0004
Revises: 20260319_0003
Create Date: 2026-03-19 07:15:00
"""

from alembic import op
import sqlalchemy as sa


revision = "20260319_0004"
down_revision = "20260319_0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("apple_reminder_mappings", sa.Column("last_acked_change_id", sa.Integer(), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_delivery_status", sa.String(length=32), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_delivery_attempt_count", sa.Integer(), nullable=True))
    op.add_column("apple_reminder_mappings", sa.Column("last_failed_change_id", sa.Integer(), nullable=True))
    op.add_column("sync_bridge_states", sa.Column("last_failed_change_id", sa.Integer(), nullable=True))

    op.create_table(
        "sync_deliveries",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("bridge_id", sa.String(length=255), nullable=False),
        sa.Column("task_id", sa.String(length=36), nullable=False),
        sa.Column("change_id", sa.Integer(), nullable=False),
        sa.Column("task_version", sa.Integer(), nullable=False),
        sa.Column("operation", sa.String(length=32), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("attempt_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("retryable", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("remote_id", sa.Text(), nullable=True),
        sa.Column("last_error_code", sa.String(length=64), nullable=True),
        sa.Column("last_error_message", sa.Text(), nullable=True),
        sa.Column("first_pushed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_pushed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("failed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("metadata", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("bridge_id", "task_id", "change_id", name="uq_sync_delivery_bridge_task_change"),
    )


def downgrade() -> None:
    op.drop_table("sync_deliveries")
    op.drop_column("sync_bridge_states", "last_failed_change_id")
    op.drop_column("apple_reminder_mappings", "last_failed_change_id")
    op.drop_column("apple_reminder_mappings", "last_delivery_attempt_count")
    op.drop_column("apple_reminder_mappings", "last_delivery_status")
    op.drop_column("apple_reminder_mappings", "last_acked_change_id")
