package kha.netsync;

import haxe.io.Bytes;
import haxe.macro.Context;
import haxe.macro.Expr;

class EntityBuilder {
	public static var nextId: Int = 0;

	macro static public function build(): Array<Field> {
		var fields = Context.getBuildFields();

		var isBaseEntity = false;
		for (i in Context.getLocalClass().get().interfaces) {
			var intf = i.t.get();
			if (intf.module == "kha.netsync.Entity") {
				isBaseEntity = true;
				break;
			}
		}

		var sendExprs: Array<Expr> = [];
		var receiveExprs: Array<Expr> = [];

		if (!isBaseEntity) {
			receiveExprs.push(macro offset += super._receive(offset, bytes));
			sendExprs.push(macro offset += super._send(offset, bytes));
		}

		var index: Int = 0;
		for (field in fields) {
			var replicated = false;
			for (meta in field.meta) {
				if (meta.name == "replicate" || meta.name == "replicated") {
					replicated = true;
					break;
				}
			}
			if (!replicated)
				continue;

			var typeName = switch (field.kind) {
				case FVar(t, e), FProp(_, _, t, e): resolveTypeName(t, e);
				default: null;
			};

			var fieldname = field.name;
			switch (typeName) {
				case "Int":
					sendExprs.push(macro bytes.setInt32(offset + $v{index}, this.$fieldname));
					receiveExprs.push(macro this.$fieldname = bytes.getInt32(offset + $v{index}));
					index += 4;
				case "Float":
					sendExprs.push(macro bytes.setDouble(offset + $v{index}, this.$fieldname));
					receiveExprs.push(macro this.$fieldname = bytes.getDouble(offset + $v{index}));
					index += 8;
				case "Bool":
					sendExprs.push(macro bytes.set(offset + $v{index}, this.$fieldname ? 1 : 0));
					receiveExprs.push(macro this.$fieldname = bytes.get(offset + $v{index}) != 0);
					index += 1;
				default:
					Context.error('Unsupported or unresolved type for @replicated field "${field.name}". Must be Int, Float, or Bool.', field.pos);
			}
		}

		sendExprs.push(macro return $v{index});
		receiveExprs.push(macro return $v{index});

		fields.push({
			name: "_send",
			doc: null,
			meta: [],
			access: isBaseEntity ? [APublic] : [APublic, AOverride],
			kind: FFun({
				ret: macro : Int,
				params: null,
				expr: macro $b{sendExprs},
				args: [
					{
						value: null,
						type: macro : Int,
						opt: null,
						name: "offset"
					},
					{
						value: null,
						type: macro : haxe.io.Bytes,
						opt: null,
						name: "bytes"
					}
				]
			}),
			pos: Context.currentPos()
		});

		fields.push({
			name: "_receive",
			doc: null,
			meta: [],
			access: isBaseEntity ? [APublic] : [APublic, AOverride],
			kind: FFun({
				ret: macro : Int,
				params: null,
				expr: macro $b{receiveExprs},
				args: [
					{
						value: null,
						type: macro : Int,
						opt: null,
						name: "offset"
					},
					{
						value: null,
						type: macro : haxe.io.Bytes,
						opt: null,
						name: "bytes"
					}
				]
			}),
			pos: Context.currentPos()
		});

		fields.push({
			name: "_id",
			doc: null,
			meta: [],
			access: isBaseEntity ? [APublic] : [APublic, AOverride],
			kind: FFun({
				ret: macro : Int,
				params: null,
				expr: macro {return __id;},
				args: []
			}),
			pos: Context.currentPos()
		});

		var sizeExpr = if (!isBaseEntity) {
			macro return super._size() + $v{index};
		}
		else {
			macro return $v{index};
		};

		fields.push({
			name: "_size",
			doc: null,
			meta: [],
			access: isBaseEntity ? [APublic] : [APublic, AOverride],
			kind: FFun({
				ret: macro : Int,
				params: null,
				expr: sizeExpr,
				args: []
			}),
			pos: Context.currentPos()
		});

		if (isBaseEntity) {
			fields.push({
				name: "__id",
				doc: null,
				meta: [],
				access: [APublic],
				kind: FVar(macro : Int, macro kha.netsync.EntityBuilder.nextId++),
				pos: Context.currentPos()
			});
		}

		return fields;
	}

	static function resolveTypeName(t: ComplexType, e: Expr): Null<String> {
		if (t != null) {
			return switch (t) {
				case TPath(p): p.name;
				default: null;
			}
		}
		if (e != null) {
			return switch (e.expr) {
				case EConst(CInt(_)) | EUnop(OpNeg, _, {expr: EConst(CInt(_))}): "Int";
				case EConst(CFloat(_)) | EUnop(OpNeg, _, {expr: EConst(CFloat(_))}): "Float";
				case EConst(CIdent("true" | "false")): "Bool";
				default: null;
			}
		}
		return null;
	}
}
