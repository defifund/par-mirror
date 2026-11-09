class CreateIpfsPins < ActiveRecord::Migration[8.0]
  def change
    # every ipfs:// logo we keep a copy of on this mirror's own IPFS node
    create_table :ipfs_pins do |t|
      t.string :cid, null: false
      t.string :status, null: false, default: "pending" # pending | pinned | failed
      t.string :source                                  # gateway the CAR came from, or "upload"
      t.bigint :bytes
      t.integer :attempts, null: false, default: 0
      t.string :error
      t.datetime :pinned_at
      t.timestamps
    end
    add_index :ipfs_pins, :cid, unique: true
    add_index :ipfs_pins, [:status, :attempts]
  end
end
