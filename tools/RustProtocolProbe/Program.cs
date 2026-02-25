using System.Text.Json;
using Mono.Cecil;
using Mono.Cecil.Cil;

if (args.Length != 1)
{
    Console.Error.WriteLine("Usage: RustProtocolProbe <path-to-Rust.Global.dll>");
    return 2;
}

var dllPath = Path.GetFullPath(args[0]);
if (!File.Exists(dllPath))
{
    Console.Error.WriteLine($"File not found: {dllPath}");
    return 2;
}

try
{
    using var module = ModuleDefinition.ReadModule(dllPath, new ReaderParameters
    {
        ReadingMode = ReadingMode.Deferred
    });

    var protocolType = module.Types.FirstOrDefault(t => t.FullName == "Rust.Protocol")
        ?? module.Types.SelectMany(t => t.NestedTypes).FirstOrDefault(t => t.FullName == "Rust.Protocol");

    if (protocolType is null)
    {
        Console.Error.WriteLine("Type Rust.Protocol not found.");
        return 1;
    }

    var cctorValues = ReadStaticCtorAssignments(protocolType);

    int? network = TryReadInt(protocolType, "network", cctorValues);
    string? printable = TryReadString(protocolType, "printable", cctorValues);

    var payload = new
    {
        ok = network.HasValue || !string.IsNullOrWhiteSpace(printable),
        protocol = new
        {
            network,
            printable
        }
    };

    Console.WriteLine(JsonSerializer.Serialize(payload, new JsonSerializerOptions
    {
        WriteIndented = true
    }));

    return payload.ok ? 0 : 1;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex);
    return 1;
}

static int? TryReadInt(TypeDefinition type, string name, StaticCtorAssignments cctorValues)
{
    var field = type.Fields.FirstOrDefault(f => f.Name == name);
    if (field is not null)
    {
        if (field.HasConstant && field.Constant is int intConstant)
        {
            return intConstant;
        }

        if (cctorValues.IntValues.TryGetValue(name, out var value))
        {
            return value;
        }
    }

    var property = type.Properties.FirstOrDefault(p => p.Name == name && p.GetMethod is not null);
    if (property?.GetMethod is not null && TryEvaluateIntGetter(property.GetMethod, type, cctorValues, out var getterValue))
    {
        return getterValue;
    }

    return null;
}

static string? TryReadString(TypeDefinition type, string name, StaticCtorAssignments cctorValues)
{
    var field = type.Fields.FirstOrDefault(f => f.Name == name);
    if (field is not null)
    {
        if (field.HasConstant && field.Constant is string stringConstant)
        {
            return stringConstant;
        }

        if (cctorValues.StringValues.TryGetValue(name, out var value))
        {
            return value;
        }
    }

    var property = type.Properties.FirstOrDefault(p => p.Name == name && p.GetMethod is not null);
    if (property?.GetMethod is not null && TryEvaluateStringGetter(property.GetMethod, type, cctorValues, out var getterValue))
    {
        return getterValue;
    }

    return null;
}

static bool TryEvaluateIntGetter(MethodDefinition getter, TypeDefinition ownerType, StaticCtorAssignments cctorValues, out int value)
{
    value = default;
    if (!getter.HasBody)
    {
        return false;
    }

    var instructions = getter.Body.Instructions;
    for (var i = 0; i < instructions.Count; i++)
    {
        var ins = instructions[i];
        if (TryReadLdcI4(ins, out var literal))
        {
            var next = NextMeaningfulInstruction(instructions, i + 1);
            if (next?.OpCode == OpCodes.Ret)
            {
                value = literal;
                return true;
            }
        }

        if (ins.OpCode == OpCodes.Ldsfld && ins.Operand is FieldReference fieldRef)
        {
            var next = NextMeaningfulInstruction(instructions, i + 1);
            if (next?.OpCode != OpCodes.Ret)
            {
                continue;
            }

            if (fieldRef.Name == "network" && cctorValues.IntValues.TryGetValue(fieldRef.Name, out var cctorVal))
            {
                value = cctorVal;
                return true;
            }

            var resolved = SafeResolve(fieldRef);
            if (resolved?.HasConstant == true && resolved.Constant is int fieldConst)
            {
                value = fieldConst;
                return true;
            }
        }
    }

    return false;
}

static bool TryEvaluateStringGetter(MethodDefinition getter, TypeDefinition ownerType, StaticCtorAssignments cctorValues, out string value)
{
    value = string.Empty;
    if (!getter.HasBody)
    {
        return false;
    }

    var instructions = getter.Body.Instructions;
    for (var i = 0; i < instructions.Count; i++)
    {
        var ins = instructions[i];
        if (ins.OpCode == OpCodes.Ldstr && ins.Operand is string literal)
        {
            var next = NextMeaningfulInstruction(instructions, i + 1);
            if (next?.OpCode == OpCodes.Ret)
            {
                value = literal;
                return true;
            }
        }

        if (ins.OpCode == OpCodes.Ldsfld && ins.Operand is FieldReference fieldRef)
        {
            var next = NextMeaningfulInstruction(instructions, i + 1);
            if (next?.OpCode != OpCodes.Ret)
            {
                continue;
            }

            if (fieldRef.Name == "printable" && cctorValues.StringValues.TryGetValue(fieldRef.Name, out var cctorVal))
            {
                value = cctorVal;
                return true;
            }

            var resolved = SafeResolve(fieldRef);
            if (resolved?.HasConstant == true && resolved.Constant is string fieldConst)
            {
                value = fieldConst;
                return true;
            }
        }
    }

    return false;
}

static Instruction? NextMeaningfulInstruction(Mono.Collections.Generic.Collection<Instruction> instructions, int startIndex)
{
    for (var i = startIndex; i < instructions.Count; i++)
    {
        var op = instructions[i].OpCode;
        if (op == OpCodes.Nop)
        {
            continue;
        }

        return instructions[i];
    }

    return null;
}

static bool TryReadLdcI4(Instruction instruction, out int value)
{
    value = instruction.OpCode.Code switch
    {
        Code.Ldc_I4_M1 => -1,
        Code.Ldc_I4_0 => 0,
        Code.Ldc_I4_1 => 1,
        Code.Ldc_I4_2 => 2,
        Code.Ldc_I4_3 => 3,
        Code.Ldc_I4_4 => 4,
        Code.Ldc_I4_5 => 5,
        Code.Ldc_I4_6 => 6,
        Code.Ldc_I4_7 => 7,
        Code.Ldc_I4_8 => 8,
        Code.Ldc_I4_S => instruction.Operand is sbyte sb ? sb : default,
        Code.Ldc_I4 => instruction.Operand is int i ? i : default,
        _ => default
    };

    return instruction.OpCode.Code is >= Code.Ldc_I4_M1 and <= Code.Ldc_I4
        && (instruction.OpCode.Code != Code.Ldc_I4_S || instruction.Operand is sbyte)
        && (instruction.OpCode.Code != Code.Ldc_I4 || instruction.Operand is int);
}

static StaticCtorAssignments ReadStaticCtorAssignments(TypeDefinition type)
{
    var result = new StaticCtorAssignments();
    var cctor = type.Methods.FirstOrDefault(m => m.IsConstructor && m.IsStatic && m.Name == ".cctor");
    if (cctor is null || !cctor.HasBody)
    {
        return result;
    }

    int? pendingInt = null;
    string? pendingString = null;

    foreach (var ins in cctor.Body.Instructions)
    {
        if (TryReadLdcI4(ins, out var intLiteral))
        {
            pendingInt = intLiteral;
            pendingString = null;
            continue;
        }

        if (ins.OpCode == OpCodes.Ldstr && ins.Operand is string strLiteral)
        {
            pendingString = strLiteral;
            pendingInt = null;
            continue;
        }

        if (ins.OpCode == OpCodes.Stsfld && ins.Operand is FieldReference fieldRef)
        {
            if (pendingInt.HasValue)
            {
                result.IntValues[fieldRef.Name] = pendingInt.Value;
            }
            else if (pendingString is not null)
            {
                result.StringValues[fieldRef.Name] = pendingString;
            }
        }
    }

    return result;
}

static FieldDefinition? SafeResolve(FieldReference fieldReference)
{
    try
    {
        return fieldReference.Resolve();
    }
    catch
    {
        return null;
    }
}

sealed class StaticCtorAssignments
{
    public Dictionary<string, int> IntValues { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> StringValues { get; } = new(StringComparer.Ordinal);
}
