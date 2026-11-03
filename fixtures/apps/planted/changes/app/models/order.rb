class Order < ApplicationRecord
  STATUSES = %w[pending paid cancelled].freeze

  belongs_to :user

  attribute :currency, default: "USD"
  attribute :status, default: "pending"

  validates :total_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[USD EUR GBP] }
  validates :status, inclusion: { in: STATUSES }

  # Enqueued after commit on purpose: Doubletrack must observe this (ADR 0004).
  after_create_commit -> { OrderConfirmationJob.perform_later(self) }

  def total
    format("%.2f", total_cents / 100.0)
  end
end
