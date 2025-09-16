# KipuBank 

A simple Ethereum smart contract that acts as a minimalistic banking system, allowing users to deposit and withdraw Ether with predefined limits.
This contract is built for educational purposes, focusing on security patterns and good practices in Solidity development.

---

## Features

* **Deposit ETH** into your personal account.
* **Withdraw ETH** with a per-transaction limit.
* **Bank capital limit** to prevent overfunding.
* **Event logging** for deposits and withdrawals.
* **Custom errors** for efficient gas usage.
* **Counters** to track total deposits and withdrawals.
* Implements the **Checks-Effects-Interactions pattern** to mitigate reentrancy risks.

---

## Functions

1. **Initialization**
   The contract is deployed with:

   * `withdrawLimit` → Maximum amount that can be withdrawn in a single transaction.
   * `bankCap` → Maximum total amount of ETH the contract can hold.

2. **Deposit**
   Users call `deposit()` and send ETH.

   * Must send a non-zero amount.
   * Cannot exceed the bank’s capital limit.
   * Balance is updated, and a `Deposit` event is emitted.

3. **Withdraw**
   Users call `withdrawl(amount)`.

   * Amount must be > 0.
   * Amount must not exceed the `withdrawLimit`.
   * User must have enough balance.
   * ETH is transferred using a safe `call`.
   * If transfer fails, state is reverted.
   * Emits a `Withdraw` event.

4. **Balance Check**

   * `getMyBalance()` returns the caller’s current balance.

---

| Function                    | Visibility         | Description                                                |
| --------------------------- | ------------------ | ---------------------------------------------------------- |
| `deposit()`                 | `external payable` | Deposits ETH into the contract.                            |
| `withdrawl(uint256 amount)` | `external`         | Withdraws ETH from the caller’s balance (up to the limit). |
| `getMyBalance()`            | `external view`    | Returns the balance of the caller.                         |
| `_getBalance(address user)` | `private view`     | Internal helper to check user balance.                     |

---

## Security Considerations

* **Reentrancy**: Prevented by following the **Checks-Effects-Interactions** pattern.
* **Gas efficiency**: Uses **custom errors** instead of `require` strings.
* **Deposit/withdraw limits**: Prevent abuse and overfunding.
* **State safety**: Rollbacks on failed ETH transfers.

⚠️ **Disclaimer**: This contract is for educational purposes only.
Do not use it in production without proper audits.

---

## Events

* `Deposit(address indexed depositor, uint256 amount, uint256 newBalance)`
* `Withdraw(address indexed withdrawer, uint256 amount, uint256 newBalance)`

These can be tracked via dApps or block explorers for activity monitoring.

---

## Informações

Autor: Luis Felipe Fabiane
Endereço do contrato implantado: https://sepolia.etherscan.io/tx/0x5cdf3e5d35446d23a68e42347c6a2db7184824719fa1a74d8984f49268d52e27
