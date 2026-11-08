# Launches whose transaction carries this mirror's salt tag (see Par::MirrorTag): lets the operator
# measure how much activity the mirror brings, e.g. before discussing an own factory with the community.
class AddViaMirrorToLaunches < ActiveRecord::Migration[8.1]
  def change
    add_column :launches, :via_mirror, :boolean, null: false, default: false
    add_index :launches, %i[chain_id via_mirror]
  end
end
