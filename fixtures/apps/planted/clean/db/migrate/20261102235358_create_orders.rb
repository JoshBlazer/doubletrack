class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :total_cents
      t.string :currency
      t.string :status

      t.timestamps
    end
  end
end
