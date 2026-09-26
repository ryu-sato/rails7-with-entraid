class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :tid, null: false
      t.string :oid, null: false
      t.string :name
      t.string :email

      t.timestamps
    end

    add_index :users, %i[tid oid], unique: true
  end
end
