"""
golden_model — Python 参考模型包
================================

提供与硬件行为一致的定点前向计算：
    reader  : 读模型同学的文本文件（net_V 真实数据已落位）
    quantize: 定点量化（Q格式/舍入/饱和）
    bn_fold : BN折叠进FC权重（真实模型无 BN，此路径不用）
    layers  : 单层前向（FC + ELU/linear）
    network : 网络级前向（7层）

使用示例：
    import sys, os
    sys.path.insert(0, "RL_project")
    from golden_model import network
    z = network.normalize_input(input_raw)
    y = network.forward_network(z)
"""
