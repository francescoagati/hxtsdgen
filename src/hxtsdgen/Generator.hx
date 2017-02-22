package hxtsdgen;

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;
using StringTools;

enum ExposeKind {
    EClass(c:ClassType);
    EMethod(c:ClassType, cf:ClassField);
}

class Generator {
    static inline var HEADER = "// Generated by Haxe TypeScript Declaration Generator :)";
    static inline var NO_EXPOSE_HINT = "// No types were @:expose'd.\n// Read more at http://haxe.org/manual/target-javascript-expose.html";

    static function use() {
        if (Context.defined("display") || !Context.defined("js"))
            return;

        Context.onGenerate(function(types) {
            var outJS = Compiler.getOutput();
            var outDTS = Path.withoutExtension(outJS) + ".d.ts";

            var exposed = [];
            for (type in types) {
                switch (type.follow()) {
                    case TInst(_.get() => cl, _):
                        if (cl.meta.has(":expose"))
                            exposed.push(EClass(cl));
                        for (f in cl.statics.get()) {
                            if (f.meta.has(":expose"))
                                exposed.push(EMethod(cl, f));
                        }
                    default:
                }
            }

            var includeHeader = !Context.defined("hxtsdgen-skip-header");

            if (exposed.length == 0) {
                var src = NO_EXPOSE_HINT;
                if (includeHeader) src = HEADER + "\n\n" + src;
                sys.io.File.saveContent(outDTS, src);
            } else {
                Context.onAfterGenerate(function() {
                    var declarations = [];
                    if (includeHeader)
                        declarations.push(HEADER);
                    for (e in exposed) {
                        switch (e) {
                            case EClass(cl):
                                declarations.push(generateClassDeclaration(cl));
                            case EMethod(cl, f):
                                declarations.push(generateFunctionDeclaration(cl, f));
                        }
                    }
                    sys.io.File.saveContent(outDTS, declarations.join("\n\n"));
                });
            }
        });
    }

    static function getExposePath(m:MetaAccess):Array<String> {
        switch (m.extract(":expose")) {
            case []: throw "no @:expose meta!"; // this should not happen
            case [{params: []}]: return null;
            case [{params: [macro $v{(s:String)}]}]: return s.split(".");
            case [_]: throw "invalid @:expose argument!"; // probably handled by compiler
            case _: throw "multiple @:expose metadata!"; // is this okay?
        }
    }

    static function wrapInNamespace(exposedPath:Array<String>, fn:String->String->String):String {
        var name = exposedPath.pop();
        return if (exposedPath.length == 0)
            fn(name, "");
        else
            'export namespace ${exposedPath.join(".")} {\n${fn(name, "\t")}\n}';
    }

    static function renderDoc(doc:String, indent:String):String {
        var parts = [];
        parts.push('$indent/**');
        var lines = doc.split("\n");
        for (line in lines) {
            line = line.trim();
            if (line.length > 0)
                parts.push('$indent * $line');
        }
        parts.push('$indent */');
        return parts.join("\n");
    }

    static function generateFunctionDeclaration(cl:ClassType, f:ClassField):String {
        var exposePath = getExposePath(f.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name, f.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];
            if (f.doc != null)
                parts.push(renderDoc(f.doc, indent));

            switch [f.kind, f.type] {
                case [FMethod(_), TFun(args, ret)]:
                    var prefix =
                        if (indent == "") // so we're not in a namespace (meh, this is hacky)
                            "export function "
                        else
                            "function ";
                    parts.push(renderFunction(name, args, ret, f.params, indent, prefix));
                default:
                    throw new Error("This kind of field cannot be exposed to JavaScript", f.pos);
            }

            return parts.join("\n");
        });
    }

    static function renderFunction(name:String, args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, params:Array<TypeParameter>, indent:String, prefix:String):String {
        var tparams = renderTypeParams(params);
        return '$indent$prefix$name$tparams(${renderArgs(args)}): ${convertTypeRef(ret)};';
    }

    static function renderTypeParams(params:Array<TypeParameter>):String {
        return
            if (params.length == 0) ""
            else "<" + params.map(function(t) return return t.name).join(", ") + ">";
    }

    static function generateClassDeclaration(cl:ClassType):String {
        var exposePath = getExposePath(cl.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];

            if (cl.doc != null)
                parts.push(renderDoc(cl.doc, indent));

            // TODO: maybe it's a good idea to output all-static class that is not referenced
            // elsewhere as a namespace for TypeScript
            var tparams = renderTypeParams(cl.params);
            parts.push('$indent${if (indent == "") "export " else ""}class $name$tparams {');

            {
                var indent = indent + "\t";

                var privateCtor = true;
                if (cl.constructor != null) {
                    var ctor = cl.constructor.get();
                    if (ctor.isPublic)
                        privateCtor = false;
                        if (ctor.doc != null)
                            parts.push(renderDoc(ctor.doc, indent));
                        switch (ctor.type) {
                            case TFun(args, _):
                                parts.push('${indent}constructor(${renderArgs(args)});');
                            default:
                                throw "wtf";
                        }
                }

                if (privateCtor)
                    parts.push('${indent}private constructor();');

                function addField(field:ClassField, isStatic:Bool) {
                    if (field.isPublic) {
                        if (field.doc != null)
                            parts.push(renderDoc(field.doc, indent));

                        var prefix = if (isStatic) "static " else "";

                        switch [field.kind, field.type] {
                            case [FMethod(_), TFun(args, ret)]:
                                parts.push(renderFunction(field.name, args, ret, field.params, indent, prefix));

                            case [FVar(_,write), _]:
                                switch (write) {
                                    case AccNo|AccNever:
                                        prefix += "readonly ";
                                    default:
                                }
                                parts.push('$indent$prefix${field.name}: ${convertTypeRef(field.type)};');

                            default:
                        }
                    }
                }

                for (field in cl.fields.get()) {
                    addField(field, false);
                }

                for (field in cl.statics.get()) {
                    addField(field, true);
                }
            }

            parts.push('$indent}');
            return parts.join("\n");
        });
    }

    static function renderArgs(args:Array<{name:String, opt:Bool, t:Type}>):String {
        // here we handle haxe's crazy argument skipping:
        // we allow trailing optional args, but if there's non-optional
        // args after the optional ones, we consider them non-optional for TS
        var noOptionalUntil = 0;
        var hadOptional = true;
        for (i in 0...args.length) {
            var arg = args[i];
            if (arg.opt) {
                hadOptional = true;
            } else if (hadOptional && !arg.opt) {
                noOptionalUntil = i;
                hadOptional = false;
            }
        }

        var tsArgs = [];
        for (i in 0...args.length) {
            var arg = args[i];
            var name = if (arg.name != "") arg.name else 'arg$i';
            var opt = if (arg.opt && i > noOptionalUntil) "?" else "";
            tsArgs.push('$name$opt: ${convertTypeRef(arg.t)}');
        }
        return tsArgs.join(", ");
    }

    static function convertTypeRef(t:Type):String {
        return switch (t) {
            case TInst(_.get() => cl, params):
                switch [cl, params] {
                    case [{pack: [], name: "String"}, _]:
                        "string";

                    case [{pack: [], name: "Array"}, [elemT]]:
                        convertTypeRef(elemT) + "[]";

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

                    case [{pack: [], name: "Bool"}, _]:
                        "boolean";

                    case [{pack: [], name: "Void"}, _]:
                        "void";

                    default:
                        // TODO: do we want to have a `type Name = Underlying` here maybe?
                        convertTypeRef(ab.type.applyTypeParameters(ab.params, params));
                }

            case TAnonymous(_.get() => anon):
                var fields = [];
                for (field in anon.fields) {
                    var opt = if (field.meta.has(":optional")) "?" else "";
                    fields.push('${field.name}$opt: ${convertTypeRef(field.type)}');
                }
                '{${fields.join(", ")}}';

            case TType(_.get() => dt, params):
                switch [dt, params] {
                    case [{pack: [], name: "Null"}, [realT]]:
                        // TODO: generate `| null` union unless it comes from an optional field?
                        convertTypeRef(realT);

                    default:
                        // TODO: generate TS interface declarations
                        convertTypeRef(dt.type.applyTypeParameters(dt.params, params));
                }

            case TFun(args, ret):
                '(${renderArgs(args)}) => ${convertTypeRef(ret)}';

            default:
                throw 'Cannot convert type ${t.toString()} to TypeScript declaration (TODO?)';
        }
    }
}
#end
