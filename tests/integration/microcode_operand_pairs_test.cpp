// Exercise the public snapshot boundary with a deterministic SDK operand pair.
// The SDK callback supplies input; no idax implementation helper is called.
#include <ida/idax.hpp>
#include <cstdarg>
#include <iostream>
#include "../../src/detail/sdk_bridge.hpp"
#include <hexrays.hpp>

namespace {
struct PairFixture {
    ida::Address function_address{ida::BadAddress};
    bool injected{false};
    bool registers_only{false};
};

ssize_t idaapi inject_operand_pair(void* context, hexrays_event_t event,
                                   va_list arguments) {
    if (event != hxe_microcode) return 0;
    auto& fixture = *static_cast<PairFixture*>(context);
    auto* microcode = va_arg(arguments, mba_t*);
    if (microcode->entry_ea != fixture.function_address || microcode->qty < 2)
        return 0;
    auto* pair = new mop_pair_t;
    if (fixture.registers_only) pair->lop.make_reg(12, 4);
    else pair->lop.make_number(0x11223344, 4);
    pair->hop.make_reg(8, 4);
    auto* instruction = new minsn_t(microcode->entry_ea);
    instruction->opcode = m_mov;
    instruction->l._make_pair(pair);
    instruction->l.size = 8;
    instruction->d.make_reg(microcode->alloc_kreg(8), 8);
    microcode->get_mblock(1)->insert_into_block(instruction, nullptr);
    fixture.injected = true;
    return 0;
}

bool is_expected_mixed_pair(const ida::decompiler::MicrocodeOperand& operand) {
    using ida::decompiler::MicrocodeOperandKind;
    if (operand.kind != MicrocodeOperandKind::OperandPair || operand.byte_width != 8
        || !operand.pair_low_operand || !operand.pair_high_operand) return false;
    const auto& low_operand = *operand.pair_low_operand;
    const auto& high_operand = *operand.pair_high_operand;
    return low_operand.kind == MicrocodeOperandKind::UnsignedImmediate
        && low_operand.unsigned_immediate == 0x11223344 && low_operand.byte_width == 4
        && high_operand.kind == MicrocodeOperandKind::Register
        && high_operand.register_id == 8 && high_operand.byte_width == 4;
}

class PairEmissionFilter final : public ida::decompiler::MicrocodeFilter {
public:
    ida::decompiler::MicrocodeOperand operand;
    bool attempted{false};
    bool passed{false};

    bool match(const ida::decompiler::MicrocodeContext&) override { return !attempted; }
    ida::decompiler::MicrocodeApplyResult apply(ida::decompiler::MicrocodeContext& context) override {
        using namespace ida::decompiler;
        attempted = true;
        auto before = context.block_instruction_count();
        auto temporary = context.allocate_temporary_register(8);
        if (!before || !temporary) return MicrocodeApplyResult::Error;
        MicrocodeInstruction instruction;
        instruction.opcode = MicrocodeOpcode::Move;
        instruction.left = operand;
        instruction.destination.kind = MicrocodeOperandKind::Register;
        instruction.destination.register_id = *temporary;
        instruction.destination.byte_width = 8;
        auto emitted = context.emit_instruction(instruction);
        if (!emitted) {
            std::cerr << "FAIL: pair re-emission: " << emitted.error().message << '\n';
            return MicrocodeApplyResult::Error;
        }
        auto copied = context.last_emitted_instruction();
        passed = copied && is_expected_mixed_pair(copied->left);
        if (!context.remove_instruction_at_index(*before)) return MicrocodeApplyResult::Error;
        for (const bool missing_member : {false, true}) {
            auto malformed = instruction;
            if (missing_member) malformed.left.pair_high_operand.reset();
            else malformed.left.byte_width = 7;
            auto rejected = context.emit_instruction(malformed);
            auto after = context.block_instruction_count();
            passed = passed && !rejected && rejected.error().category == ida::ErrorCategory::Validation
                && after && *after == *before;
        }
        return MicrocodeApplyResult::NotHandled;
    }
};
}

int main(int argument_count, char** arguments) {
    if (argument_count != 2 || !ida::database::init(argument_count, arguments)
        || !ida::database::open(arguments[1])) return 1;
    struct DatabaseCloser {
        ~DatabaseCloser() { (void)ida::database::close(false); }
    } database_closer;
    if (!ida::analysis::wait()) return 1;
    auto available = ida::decompiler::available();
    if (!available || !*available) {
        std::cerr << "FAIL: Hex-Rays is required for the pair regression\n";
        return 1;
    }
    PairFixture fixture;
    for (const auto& function : ida::function::all()) {
        if (function.name() == "target") fixture.function_address = function.start();
    }
    if (fixture.function_address == ida::BadAddress
        || !install_hexrays_callback(inject_operand_pair, &fixture)) return 1;
    ida::decompiler::MicrocodeGenerationOptions options;
    options.maturity = ida::decompiler::MicrocodeMaturity::Generated;
    auto snapshot = ida::decompiler::generate_microcode(fixture.function_address, options);
    remove_hexrays_callback(inject_operand_pair, &fixture);
    if (!fixture.injected) {
        std::cerr << "FAIL: operand-pair input was not exercised\n";
        return 1;
    }
    if (!snapshot) {
        std::cerr << "FAIL: a constant/register operand pair could not be exported: "
                  << snapshot.error().message << '\n';
        return 1;
    }
    std::optional<ida::decompiler::MicrocodeOperand> retained_pair;
    for (const auto& block : snapshot->blocks) {
        for (const auto& instruction : block.instructions) {
            const auto& operand = instruction.left;
            if (operand.kind != ida::decompiler::MicrocodeOperandKind::OperandPair) continue;
            if (!is_expected_mixed_pair(operand)) return 1;
            retained_pair = operand;
        }
    }
    if (!retained_pair) {
        std::cerr << "FAIL: exported snapshot lost the operand pair\n";
        return 1;
    }
    fixture.registers_only = true;
    fixture.injected = false;
    if (!install_hexrays_callback(inject_operand_pair, &fixture)) return 1;
    auto register_snapshot = ida::decompiler::generate_microcode(fixture.function_address, options);
    remove_hexrays_callback(inject_operand_pair, &fixture);
    if (!register_snapshot || !fixture.injected) return 1;
    bool preserved_register_pair = false;
    for (const auto& block : register_snapshot->blocks) {
        for (const auto& instruction : block.instructions) {
            const auto& operand = instruction.left;
            preserved_register_pair |= operand.kind == ida::decompiler::MicrocodeOperandKind::RegisterPair
                && operand.register_id == 12 && operand.second_register_id == 8 && operand.byte_width == 8;
        }
    }
    if (!preserved_register_pair) return 1;
    auto filter = std::make_shared<PairEmissionFilter>();
    filter->operand = *retained_pair;
    auto token = ida::decompiler::register_microcode_filter(filter);
    if (!token) return 1;
    auto emitted_snapshot = ida::decompiler::generate_microcode(fixture.function_address, options);
    auto removed = ida::decompiler::unregister_microcode_filter(*token);
    if (!emitted_snapshot || !removed || !filter->attempted || !filter->passed) return 1;
    snapshot = {};
    if (!is_expected_mixed_pair(*retained_pair)) return 1;
    std::cout << "PASS: mixed pair export, ownership, re-emission, malformed inputs, and register-pair compatibility\n";
    return 0;
}
