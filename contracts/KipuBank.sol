// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBank
 * @author Luis Felipe Fabiane
 * @notice Um contrato de "banco" simples que permite aos usuários depositar e sacar Ether, com limites de transação e limites de capital do banco.
 * @dev Este contrato implementa funcionalidades básicas de um cofre de ETH, focado em aprendizagem e boas práticas de desenvolvimento Solidity.
 */
contract KipuBank {
    mapping(address => uint256) private balances;
    uint256 public immutable withdrawLimit;
    uint256 public immutable bankCap;
    uint256 public depositCount;
    uint256 public withdrawCount;

    event Deposit(address indexed depositor, uint256 amount, uint256 newBalance);

    event Withdraw(address indexed withdrawer, uint256 amount, uint256 newBalance);

    error ZeroAmount();
    
    error BankCapExceeded(uint256 requestedDeposit, uint256 currentCap, uint256 bankCap);

    error WithdrawLimitExceeded(uint256 requestedWithdraw, uint256 withdrawCount);

    error InsuficientBalance(uint256 requestedWithdraw, uint256 currentBalance);
    
    /**
     * @notice Construtor que inicializa o contrato com os limites de saque e capital.
     * @param withdrawLimitInit O limite máximo de saque por transação.
     * @param bankCapInit O limite de capital total do banco.
     */
    constructor(uint256 withdrawLimitInit, uint256 bankCapInit) {
        if (withdrawLimitInit <= 0 || bankCapInit <= 0) {
            revert ZeroAmount();
        }
        withdrawLimit = withdrawLimitInit;
        bankCap = bankCapInit;
    }

    /**
     * @dev Modificador para validar se o valor depositado não excede o capital limite do banco.
     * @param amount O valor de ETH a ser depositado.
     */
    modifier _bankCapCheck(uint256 amount) {
        if (address(this).balance + amount > bankCap) {
            revert BankCapExceeded(amount, address(this).balance, bankCap);
        }
        _;
    }

    /**
     * @notice Permite a um usuário depositar ETH em sua conta.
     * @dev Esta função utiliza o padrão "checks-effects-interactions".
     * Primeiro, verifica se o valor não é zero e se não excede o limite do banco.
     * Depois, atualiza o saldo do usuário e o contador de depósitos.
     * Finalmente, emite o evento para notificar o sucesso.
     */
    function deposit() external payable _bankCapCheck(msg.value) {
        if (msg.value == 0) {
            revert ZeroAmount();
        }

        balances[msg.sender] += msg.value;
        depositCount += 1;

        emit Deposit(msg.sender, msg.value, balances[msg.sender]);
    }


    /**
     * @notice Permite a um usuário sacar ETH de sua conta.
     * @dev Esta função implementa o padrão "checks-effects-interactions" para prevenir ataques de reentrância.
     * Primeiro, verifica se o valor solicitado não excede o limite de saque e se o usuário tem saldo suficiente.
     * Depois, atualiza o estado interno do contrato (diminui o saldo do usuário).
     * Por fim, interage com o exterior enviando os fundos e emite o evento de sucesso.
     * @param amount O valor de ETH a ser sacado.
     */
    function withdrawl(uint256 amount) external {
        if (amount <= 0) {
            revert ZeroAmount();
        }
        if (amount > withdrawLimit) {
            revert WithdrawLimitExceeded(amount, withdrawLimit);
        }
        if (balances[msg.sender]  < amount) {
            revert InsuficientBalance(amount, balances[msg.sender]);
        }

        balances[msg.sender] -= amount;
        withdrawCount++;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            balances[msg.sender] += amount;
            withdrawCount--;
        }

        emit Withdraw(msg.sender, amount, balances[msg.sender]);
    }

    /**
     * @dev Função de suporte interna para obter o saldo de um endereço.
     * @param user O endereço do qual se deseja obter o saldo.
     * @return O saldo de ETH do usuário.
     */
    function _getBalance(address user) private view returns (uint256) {
        return balances[user];
    }
    
    /**
     * @notice Retorna o saldo de ETH do chamador.
     * @dev Esta função é uma view, o que significa que não altera o estado do contrato e não custa gás ao ser chamada.
     * @return O saldo de ETH do chamador.
     */
    function getMyBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

}
