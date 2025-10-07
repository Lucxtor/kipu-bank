// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IChainlink {
    function latestAnswer()
    external
    view
    returns (
        uint256
    );
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title KipuBank
 * @author Luis Felipe Fabiane
 * @notice Um contrato de "banco" simples que permite aos usuários depositar e sacar Ether, com limites de transação e limites de capital do banco.
 * @dev Este contrato implementa funcionalidades básicas de um cofre de ETH, focado em aprendizagem e boas práticas de desenvolvimento Solidity.
 */
contract KipuBank is AccessControl {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");

    mapping(address => mapping(address => uint256)) private tokenBalances;
    uint256 public immutable usdWithdrawLimit;
    uint256 public immutable bankCap;
    uint256 public depositCount;
    uint256 public withdrawCount;
    IChainlink oracle;

    event Deposit(address indexed depositor, uint256 amount, uint256 newBalance);

    event BalanceChange(address indexed admin, address indexed user, uint256 newBalance);

    event Withdraw(address indexed withdrawer, uint256 amount, uint256 newBalance);

    event TokenDeposit(address indexed token, address indexed depositor, uint256 amount, uint256 newBalance);

    event TokenWithdraw(address indexed token, address indexed withdrawer, uint256 amount, uint256 newBalance);

    error ZeroAmount();
    
    error BankCapExceeded(uint256 requestedDeposit, uint256 currentCap, uint256 bankCap);

    error usdWithdrawLimitExceeded(uint256 requestedWithdraw, uint256 usdWithdrawLimit);

    error InsuficientBalance(uint256 requestedWithdraw, uint256 currentBalance);
    
    /**
     * @notice Construtor que inicializa o contrato com os limites de saque e capital.
     * @param _admin O endereço do admin do contrato.
     * @param _usdWithdrawLimit O limite máximo de saque por transação.
     * @param _bankCap O limite de capital total do banco.
     * @param _oracle O endereço do fornecedor de informações externas.
     */
    constructor(address _admin, uint256 _usdWithdrawLimit, uint256 _bankCap, IChainlink _oracle) {
        if (_usdWithdrawLimit <= 0 || _bankCap <= 0) {
            revert ZeroAmount();
        }

        _grantRole(ADMIN_ROLE, _admin);

        usdWithdrawLimit = _usdWithdrawLimit * 1e8;
        bankCap = _bankCap;
        oracle = _oracle;
    }

    /**
     * @dev Modificador para validar se o valor depositado não excede o capital limite do banco.
     * @param token O endereço do token depositado, 0 se for eth
     * @param amount O valor de ETH a ser depositado.
     */
    modifier _bankCapCheck(address token, uint256 amount) {
        if (token == address(0)) {
            if (address(this).balance + amount > bankCap) {
                revert BankCapExceeded(amount, address(this).balance, bankCap);
            }
        }
        _;
    }

    /**
     * @notice Permite a um usuário depositar ETH em sua conta.
     * @param token Endereço do token depositado, 0 se for eth
     * @param amount Quantidade do token depositado, 0 se for eth
     * @dev Esta função utiliza o padrão "checks-effects-interactions".
     * Primeiro, verifica se o valor não é zero e se não excede o limite do banco.
     * Depois, atualiza o saldo do usuário e o contador de depósitos.
     * Finalmente, emite o evento para notificar o sucesso.
     */
    function deposit(address token, uint256 amount) external payable _bankCapCheck(token, msg.value) {
        if (token == address(0)) {
            if (msg.value == 0) {
                revert ZeroAmount();
            }
            tokenBalances[address(0)][msg.sender] += msg.value;

            emit Deposit(msg.sender, msg.value, tokenBalances[address(0)][msg.sender]);
        } else {
            if (amount == 0) {
                revert ZeroAmount();
            }
            
            IERC20(token).transferFrom(msg.sender, address(this), amount);
            tokenBalances[token][msg.sender] += amount;

            emit TokenDeposit(token, msg.sender, amount > 0 ? amount : msg.value, tokenBalances[token][msg.sender]);
        }

    }


    /**
     * @notice Permite a um usuário sacar ETH de sua conta.
     * @dev Esta função implementa o padrão "checks-effects-interactions" para prevenir ataques de reentrância.
     * Primeiro, verifica se o valor solicitado não excede o limite de saque e se o usuário tem saldo suficiente.
     * Depois, atualiza o estado interno do contrato (diminui o saldo do usuário).
     * Por fim, interage com o exterior enviando os fundos e emite o evento de sucesso.
     * @param amount O valor de ETH a ser sacado.
     */
    function withdraw(address token, uint256 amount) external {
        if (amount <= 0) {
            revert ZeroAmount();
        }

        uint256 ethPrice = getEthPrice();

        uint256 withdrawLimit = (usdWithdrawLimit * 1e18) / ethPrice;

        if (amount > withdrawLimit) {
            revert usdWithdrawLimitExceeded(amount, usdWithdrawLimit);
        }
        
        if (tokenBalances[token][msg.sender]  < amount) {
            revert InsuficientBalance(amount, tokenBalances[token][msg.sender]);
        }

        tokenBalances[token][msg.sender] -= amount;
        withdrawCount++;

        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) {
                tokenBalances[token][msg.sender] += amount;
                withdrawCount--;
            }

            emit Withdraw(msg.sender, amount, tokenBalances[token][msg.sender]);
        } else {
            IERC20(token).transfer(msg.sender, amount);

            emit TokenWithdraw(token, msg.sender, amount, tokenBalances[token][msg.sender]);
        }
    }

    /**
     * @dev Função de suporte interna para ajustar o saldo de um endereço.
     * @param user O endereço do qual se deseja ajustar o saldo.
     * @param token O endereço do token que se deseja obter o saldo.
     * @param amount O novo saldo de ETH do usuário.
     */
    function changeUserBalance(address user, address token, uint256 amount) public onlyRole(ADMIN_ROLE) {
        tokenBalances[token][user] = amount;

        emit BalanceChange(msg.sender, user, amount);
    }

    /**
     * @dev Função de suporte interna para obter o saldo de um endereço.
     * @param user O endereço do qual se deseja obter o saldo.
     * @param token O endereço do token que se deseja obter o saldo.
     * @return O saldo de ETH do usuário.
     */
    function getUserBalance(address user, address token) public onlyRole(ADMIN_ROLE) view returns (uint256) {
        return tokenBalances[token][user];
    }
    
    /**
     * @notice Retorna o saldo de ETH do chamador.
     * @param token O endereço do token que se deseja obter o saldo.
     * @dev Esta função é uma view, o que significa que não altera o estado do contrato e não custa gás ao ser chamada.
     * @return O saldo de ETH do chamador.
     */
    function getMyBalance(address token) external view returns (uint256) {
        return tokenBalances[token][msg.sender];
    }

    function getEthPrice() public view returns (uint256) {
        return oracle.latestAnswer();
        // return IChainlink(0x694AA1769357215DE4FAC081bf1f309aDC325306).latestAnswer();
    }

}
