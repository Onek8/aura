package aura.utils;

@:generic
class Pointer<T> {
	public var value: Null<T>;

	public inline function new(value: Null<T> = null) {
		set(value);
	}

	public inline function set(value: Null<T>) {
		this.value = value;
	}

	public inline function get(): Null<T> {
		return this.value;
	}

	public inline function getSure(): T {
		return this.value;
	}
}

/**
	Workaround for covariance issues when using generics. Use `PointerType<T>`
	instead of `Pointer<T>` when using generic pointers as function parameters.
**/
@:generic
typedef PointerType<T> = {
	public var value:Null<T>;

	public function set(value: Null<T>): Void;
	public function get(): Null<T>;
}
