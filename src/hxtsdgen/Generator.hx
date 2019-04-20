package hxtsdgen;

import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;

import hxtsdgen.DocRenderer.renderDoc;
import hxtsdgen.ArgsRenderer.renderArgs;
import hxtsdgen.TypeRenderer.renderType;

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
                    var gen = new Generator();
                    var declarations = gen.generate(exposed);

                    if (includeHeader)
                        declarations.unshift(HEADER);

                    sys.io.File.saveContent(outDTS, declarations.join("\n\n"));
                });
            }
        });
    }

    var declarations:Array<String>;

    function new() {
        this.declarations = [];
    }

    function generate(exposed:Array<ExposeKind>) {
        for (e in exposed) {
            switch (e) {
                case EClass(cl):
                    declarations.push(generateClassDeclaration(cl));
                case EMethod(cl, f):
                    declarations.push(generateFunctionDeclaration(cl, f));
            }
        }
        return declarations;
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
        return fn(name, "");
        //return if (exposedPath.length == 0)
        //    fn(name, "");
        //else
        //    'export namespace ${exposedPath.join(".")} {\n${fn(name, "\t")}\n}';
    }

    function generateFunctionDeclaration(cl:ClassType, f:ClassField):String {
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

    function renderFunction(name:String, args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, params:Array<TypeParameter>, indent:String, prefix:String):String {
        var tparams = renderTypeParams(params);
        var render_args = renderArgs(this, args);
        var render_type = renderType(this, ret);

        return '$indent$prefix$name$tparams(${render_args}): ${render_type};';
    }

    static function renderTypeParams(params:Array<TypeParameter>):String {
        return
            if (params.length == 0) ""
            else "<" + params.map(function(t) return return t.name).join(", ") + ">";
    }

    function generateClassDeclaration(cl:ClassType):String {
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
            var isInterface = cl.isInterface;
            var type = isInterface ? 'interface' : 'class';
            parts.push('$indent${if (indent == "") "export " else ""}$type $name$tparams {');

            {
                var indent = indent + "\t";
                var privateCtor = true;
                if (cl.constructor != null) {
                    var ctor = cl.constructor.get();
                    privateCtor = false;
                    if (ctor.doc != null)
                        parts.push(renderDoc(ctor.doc, indent));
                    switch (ctor.type) {
                        case TFun(args, _):
                            var prefix = if (ctor.isPublic) "" else "private "; // TODO: should this really be protected?
                            parts.push('${indent}${prefix}constructor(${renderArgs(this, args)});');
                        default:
                            throw "wtf";
                    }
                } else if (!isInterface) {
                    parts.push('${indent}private constructor();');
                }

                function addField(field:ClassField, isStatic:Bool) {
                    if (field.isPublic) {
                        if (field.doc != null)
                            parts.push(renderDoc(field.doc, indent));

                        var prefix = if (isStatic) "static " else "";
                        switch [field.kind, field.type] {
                            case [FMethod(_), TFun(args, ret)]:{
                                parts.push(renderFunction(field.name, args, ret, field.params, indent, prefix));

                            }
                                
                            case [FVar(_,write), _]:{
                                switch (write) {
                                    case AccNo|AccNever:
                                        prefix += "readonly ";
                                    default:
                                }
                                var option = isInterface && isNullable(field) ? '?' : '';
                                parts.push('$indent$prefix${field.name}$option: ${renderType(this, field.type)};');


                            }

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

    function isNullable(field:ClassField) {
        return switch (field.type) {
            case TType(_.get() => _.name => 'Null', _): true;
            default: false;
        }
    }

}
