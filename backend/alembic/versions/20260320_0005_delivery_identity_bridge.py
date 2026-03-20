"""add delivery identity bridge fields

Revision ID: 20260320_0005
Revises: 20260319_0004
Create Date: 2026-03-20 19:30:00
"""

from alembic import op
import sqlalchemy as sa


revision = "20260320_0005"
down_revision = "20260319_0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("sync_bridge_states", sa.Column("next_delivery_seq", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("sync_bridge_states", sa.Column("last_acked_delivery_seq", sa.Integer(), nullable=True))
    op.add_column("sync_bridge_states", sa.Column("last_failed_delivery_seq", sa.Integer(), nullable=True))
    op.add_column("sync_bridge_states", sa.Column("last_seen_delivery_seq", sa.Integer(), nullable=True))

    op.add_column("sync_deliveries", sa.Column("delivery_id", sa.Uuid(), nullable=True))
    op.add_column("sync_deliveries", sa.Column("delivery_seq", sa.Integer(), nullable=True))
    op.add_column("sync_deliveries", sa.Column("superseded_by_delivery_id", sa.Uuid(), nullable=True))

    op.execute("UPDATE sync_deliveries SET delivery_id = id WHERE delivery_id IS NULL")
    op.execute(
        """
        WITH ranked AS (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY bridge_id ORDER BY created_at, id) AS seq
            FROM sync_deliveries
        )
        UPDATE sync_deliveries
        SET delivery_seq = ranked.seq
        FROM ranked
        WHERE sync_deliveries.id = ranked.id
        """
    )
    op.execute(
        """
        UPDATE sync_bridge_states
        SET next_delivery_seq = COALESCE((
            SELECT MAX(sync_deliveries.delivery_seq) + 1
            FROM sync_deliveries
            WHERE sync_deliveries.bridge_id = sync_bridge_states.bridge_id
        ), 1)
        """
    )
    op.execute(
        """
        UPDATE sync_bridge_states
        SET last_seen_delivery_seq = (
            SELECT MAX(sync_deliveries.delivery_seq)
            FROM sync_deliveries
            WHERE sync_deliveries.bridge_id = sync_bridge_states.bridge_id
        )
        """
    )

    op.alter_column("sync_deliveries", "delivery_id", nullable=False)
    op.alter_column("sync_deliveries", "delivery_seq", nullable=False)
    op.create_unique_constraint("uq_sync_delivery_delivery_id", "sync_deliveries", ["delivery_id"])
    op.create_unique_constraint("uq_sync_delivery_bridge_seq", "sync_deliveries", ["bridge_id", "delivery_seq"])


def downgrade() -> None:
    op.drop_constraint("uq_sync_delivery_bridge_seq", "sync_deliveries", type_="unique")
    op.drop_constraint("uq_sync_delivery_delivery_id", "sync_deliveries", type_="unique")
    op.drop_column("sync_deliveries", "superseded_by_delivery_id")
    op.drop_column("sync_deliveries", "delivery_seq")
    op.drop_column("sync_deliveries", "delivery_id")
    op.drop_column("sync_bridge_states", "last_seen_delivery_seq")
    op.drop_column("sync_bridge_states", "last_failed_delivery_seq")
    op.drop_column("sync_bridge_states", "last_acked_delivery_seq")
    op.drop_column("sync_bridge_states", "next_delivery_seq")
