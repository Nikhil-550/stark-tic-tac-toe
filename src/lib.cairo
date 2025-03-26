use starknet::ContractAddress;
use core::traits::TryInto;
use core::option::OptionTrait;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(
        ref self: TContractState, 
        from: ContractAddress, 
        to: ContractAddress, 
        amount: u256
    ) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
}

#[starknet::interface]
trait IStakingContract<TContractState> {
    // Stake tokens
    fn stake(ref self: TContractState, amount: u256);
    
    // Withdraw staked tokens
    fn withdraw(ref self: TContractState, amount: u256);
    
    // Claim rewards
    fn claim_rewards(ref self: TContractState);
    
    // Get user's staked amount
    fn get_staked_amount(self: @TContractState, user: ContractAddress) -> u256;
    
    // Get user's pending rewards
    fn get_pending_rewards(self: @TContractState, user: ContractAddress) -> u256;
}

#[starknet::contract]
mod StakingContract {
    use starknet::get_caller_address;
    use starknet::ContractAddress;
    use starknet::storage::Map;
    use super::IERC20Dispatcher;
    use super::IERC20DispatcherTrait;
    use core::traits::TryInto;
    use core::option::OptionTrait;

    // Constants for rewards calculation
    const REWARDS_PRECISION: u256 = 1_000_000_000_000_000_000; // 18 decimals
    const SECONDS_PER_YEAR: u256 = 31_536_000; // 365 * 24 * 60 * 60
    const BASE_APY: u256 = 10; // 10% base APY

    #[storage]
    struct Storage {
        // Staking token contract address
        staking_token: ContractAddress,
        
        // Reward token contract address
        reward_token: ContractAddress,
        
        // Total tokens staked in the contract
        total_staked: u256,
        
        // Mapping of user staked amounts
        user_stakes: Map<ContractAddress, u256>,
        
        // Mapping of user stake timestamps
        user_stake_times: Map<ContractAddress, u64>,
        
        // Mapping of user claimed rewards
        user_claimed_rewards: Map<ContractAddress, u256>,
        
        // Accumulated rewards per token
        accumulated_rewards_per_token: u256,
        
        // Last update timestamp
        last_update_timestamp: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Staked: Staked,
        Withdrawn: Withdrawn,
        RewardsClaimed: RewardsClaimed,
    }

    #[derive(Drop, starknet::Event)]
    struct Staked {
        user: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawn {
        user: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardsClaimed {
        user: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, 
        staking_token_address: ContractAddress,
        reward_token_address: ContractAddress
    ) {
        self.staking_token.write(staking_token_address);
        self.reward_token.write(reward_token_address);
        self.last_update_timestamp.write(starknet::get_block_timestamp());
    }

    #[abi(embed_v0)]
    impl StakingContractImpl of super::IStakingContract<ContractState> {
        fn stake(ref self: ContractState, amount: u256) {
            let sender = get_caller_address();
            
            // Update rewards before staking
            self.update_rewards();
            
            // Transfer tokens from user to contract
            let staking_token = IERC20Dispatcher { 
                contract_address: self.staking_token.read() 
            };
            let transfer_success = staking_token.transfer_from(
                sender, 
                starknet::get_contract_address(), 
                amount
            );
            assert(transfer_success, 'Token transfer failed');
            
            // Update user's stake
            let current_stake = self.user_stakes.read(sender);
            let new_stake = current_stake + amount;
            self.user_stakes.write(sender, new_stake);
            
            // Update total staked amount
            self.total_staked.write(self.total_staked.read() + amount);
            
            // Update stake timestamp
            self.user_stake_times.write(sender, starknet::get_block_timestamp());
            
            // Emit event
            self.emit(Staked { user: sender, amount });
        }
        
        fn withdraw(ref self: ContractState, amount: u256) {
            let sender = get_caller_address();
            
            // Update rewards before withdrawal
            self.update_rewards();
            
            // Check sufficient stake
            let current_stake = self.user_stakes.read(sender);
            assert(current_stake >= amount, 'Insufficient stake');
            
            // Transfer tokens back to user
            let staking_token = IERC20Dispatcher { 
                contract_address: self.staking_token.read() 
            };
            let transfer_success = staking_token.transfer(sender, amount);
            assert(transfer_success, 'Token transfer failed');
            
            // Update user's stake
            let new_stake = current_stake - amount;
            self.user_stakes.write(sender, new_stake);
            
            // Update total staked amount
            self.total_staked.write(self.total_staked.read() - amount);
            
            // Emit event
            self.emit(Withdrawn { user: sender, amount });
        }
        
        fn claim_rewards(ref self: ContractState) {
            let sender = get_caller_address();
            
            // Calculate and update rewards
            self.update_rewards();
            
            // Calculate pending rewards
            let pending_rewards = self.get_pending_rewards(sender);
            assert(pending_rewards > 0, 'No rewards to claim');
            
            // Transfer rewards
            let reward_token = IERC20Dispatcher { 
                contract_address: self.reward_token.read() 
            };
            let transfer_success = reward_token.transfer(sender, pending_rewards);
            assert(transfer_success, 'Reward transfer failed');
            
            // Update claimed rewards
            let total_claimed = self.user_claimed_rewards.read(sender);
            self.user_claimed_rewards.write(sender, total_claimed + pending_rewards);
            
            // Emit event
            self.emit(RewardsClaimed { user: sender, amount: pending_rewards });
        }
        
        fn get_staked_amount(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_stakes.read(user)
        }
        
        fn get_pending_rewards(self: @ContractState, user: ContractAddress) -> u256 {
            let user_stake = self.user_stakes.read(user);
            if user_stake == 0 {
                return 0;
            }
            
            let current_timestamp = starknet::get_block_timestamp();
            let stake_timestamp = self.user_stake_times.read(user);
            
            // Convert staking duration to u256
            let staking_duration: u256 = (current_timestamp - stake_timestamp).into();
            
            // Calculate rewards based on simple APY
            let annual_rewards = (user_stake * BASE_APY) / 100;
            let prorated_rewards = (annual_rewards * staking_duration) / SECONDS_PER_YEAR;
            
            // Subtract already claimed rewards
            let claimed_rewards = self.user_claimed_rewards.read(user);
            
            if prorated_rewards > claimed_rewards {
                prorated_rewards - claimed_rewards
            } else {
                0
            }
        }
    }

    // Internal functions
    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn update_rewards(ref self: ContractState) {
            let current_timestamp = starknet::get_block_timestamp();
            let last_update = self.last_update_timestamp.read();
            
            // Only update if time has passed
            if current_timestamp > last_update {
                // Update accumulated rewards per token logic would go here
                // This is a simplified version
                self.last_update_timestamp.write(current_timestamp);
            }
        }
    }
}