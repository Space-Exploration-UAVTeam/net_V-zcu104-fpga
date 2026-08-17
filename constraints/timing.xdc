## net_v_top 时序约束 —— 阶段 4 综合/实现验证用
## 目标频率 100MHz（周期 10ns）。板上时钟来源在阶段 5（Block Design）
## 由 PS 侧提供，这里只对纯 PL 逻辑做时序收敛检查。
create_clock -period 10.000 -name sys_clk [get_ports clk]
