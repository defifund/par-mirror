class AddBackedUpAtToIpfsPins < ActiveRecord::Migration[8.0]
  def change
    add_column :ipfs_pins, :backed_up_at, :datetime # copy of the CAR in R2 (see BackupPinsJob)
    add_index :ipfs_pins, :backed_up_at
  end
end
