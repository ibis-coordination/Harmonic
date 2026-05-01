class AddLotteryBeaconToDecisions < ActiveRecord::Migration[7.2]
  def change
    add_column :decisions, :lottery_beacon_round, :bigint
    add_column :decisions, :lottery_beacon_randomness, :string
  end
end
