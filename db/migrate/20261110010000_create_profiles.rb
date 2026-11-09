class CreateProfiles < ActiveRecord::Migration[8.0]
  def change
    # wallet-signed (SIWE) profiles: a name and a few words next to an address, kept on this mirror only
    create_table :profiles do |t|
      t.string :address, null: false
      t.string :name
      t.string :bio
      t.string :avatar
      t.jsonb :socials, null: false, default: {}
      t.timestamps
    end
    add_index :profiles, :address, unique: true

    # a token's creator can correct its description, image and links here (on-chain metadata is fixed at launch)
    create_table :token_profiles do |t|
      t.integer :chain_id, null: false
      t.string :token, null: false
      t.text :description
      t.string :logo
      t.jsonb :socials, null: false, default: {}
      t.string :updated_by, null: false
      t.timestamps
    end
    add_index :token_profiles, [:chain_id, :token], unique: true
  end
end
