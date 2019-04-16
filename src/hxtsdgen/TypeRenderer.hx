package hxtsdgen;

import haxe.macro.Type;
using haxe.macro.Tools;

import hxtsdgen.ArgsRenderer.renderArgs;

class TypeRenderer {
    public static function renderType(ctx:Generator, t:Type, paren = false):String {
        inline function wrap(s) return if (paren) '($s)' else s;

        return switch (t) {
            case TInst(_.get() => cl, params):
                switch [cl, params] {
                    case [{pack: [], name: "String"}, _]:
                        "string";

                    case [{pack: [], name: "Array"}, [elemT]]:
                        renderType(ctx, elemT, true) + "[]";

                    case [{name: name, kind: KTypeParameter(_)}, _]:
                        name;

                    default:
                        // TODO: handle @:expose'd paths
                        haxe.macro.MacroStringTools.toDotPath(cl.pack, cl.name);
                }

            case TAbstract(_.get() => ab, params):
                switch [ab, params] {
                    case [{pack: [], name: "Int" | "Float"}, _]:
                        "number";

                    case [{pack: [], name: "String"}, _]:
                        "string";

                    case [{pack: [], name: "Bool"}, _]:
                        "boolean";

                    case [{pack: [], name: "Void"}, _]:
                        "void";

                    case [{pack: ["haxe", "extern"], name: "EitherType"}, [aT, bT]]:
                        'any';
                        '${renderType(ctx, aT, true)} | ${renderType(ctx, bT, true)}';

                    default:
                        'any';
                        // TODO: do we want to have a `type Name = Underlying` here maybe?
                        //renderType(ctx, ab.type.applyTypeParameters(ab.params, params), paren);
                } 

            case TAnonymous(_.get() => anon):
                var fields = [];
                for (field in anon.fields) {
                    var opt = if (field.meta.has(":optional")) "?" else "";
                    fields.push('${field.name}$opt: ${renderType(ctx, field.type)}');
                }
                '{${fields.join(", ")}}';

            case TType(_.get() => dt, params):
                switch [dt, params] {
                    case [{pack: [], name: "Null"}, [realT]]:
                        // TODO: generate `| null` union unless it comes from an optional field?
                        renderType(ctx, realT, paren);

                    default:
                        // TODO: generate TS interface declarations
                        renderType(ctx, dt.type.applyTypeParameters(dt.params, params), paren);
                }

            case TFun(args, ret):
                wrap('(${renderArgs(ctx, args)}) => ${renderType(ctx, ret)}');

            case TDynamic(null):
                'any';

            case TDynamic(elemT):
                '{ [key: string]: ${renderType(ctx, elemT)} }';

            default:
                'any';
                //throw 'Cannot render type ${t.toString()} into a TypeScript declaration (TODO?)';
        }
    }
}
