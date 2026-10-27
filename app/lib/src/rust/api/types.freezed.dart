// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$UiEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent()';
}


}

/// @nodoc
class $UiEventCopyWith<$Res>  {
$UiEventCopyWith(UiEvent _, $Res Function(UiEvent) __);
}


/// Adds pattern-matching-related methods to [UiEvent].
extension UiEventPatterns on UiEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UiEvent_Task value)?  task,TResult Function( UiEvent_TasksChanged value)?  tasksChanged,TResult Function( UiEvent_SettingsChanged value)?  settingsChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UiEvent_Task() when task != null:
return task(_that);case UiEvent_TasksChanged() when tasksChanged != null:
return tasksChanged(_that);case UiEvent_SettingsChanged() when settingsChanged != null:
return settingsChanged(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UiEvent_Task value)  task,required TResult Function( UiEvent_TasksChanged value)  tasksChanged,required TResult Function( UiEvent_SettingsChanged value)  settingsChanged,}){
final _that = this;
switch (_that) {
case UiEvent_Task():
return task(_that);case UiEvent_TasksChanged():
return tasksChanged(_that);case UiEvent_SettingsChanged():
return settingsChanged(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UiEvent_Task value)?  task,TResult? Function( UiEvent_TasksChanged value)?  tasksChanged,TResult? Function( UiEvent_SettingsChanged value)?  settingsChanged,}){
final _that = this;
switch (_that) {
case UiEvent_Task() when task != null:
return task(_that);case UiEvent_TasksChanged() when tasksChanged != null:
return tasksChanged(_that);case UiEvent_SettingsChanged() when settingsChanged != null:
return settingsChanged(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( UiTask field0)?  task,TResult Function()?  tasksChanged,TResult Function()?  settingsChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UiEvent_Task() when task != null:
return task(_that.field0);case UiEvent_TasksChanged() when tasksChanged != null:
return tasksChanged();case UiEvent_SettingsChanged() when settingsChanged != null:
return settingsChanged();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( UiTask field0)  task,required TResult Function()  tasksChanged,required TResult Function()  settingsChanged,}) {final _that = this;
switch (_that) {
case UiEvent_Task():
return task(_that.field0);case UiEvent_TasksChanged():
return tasksChanged();case UiEvent_SettingsChanged():
return settingsChanged();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( UiTask field0)?  task,TResult? Function()?  tasksChanged,TResult? Function()?  settingsChanged,}) {final _that = this;
switch (_that) {
case UiEvent_Task() when task != null:
return task(_that.field0);case UiEvent_TasksChanged() when tasksChanged != null:
return tasksChanged();case UiEvent_SettingsChanged() when settingsChanged != null:
return settingsChanged();case _:
  return null;

}
}

}

/// @nodoc


class UiEvent_Task extends UiEvent {
  const UiEvent_Task(this.field0): super._();
  

 final  UiTask field0;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_TaskCopyWith<UiEvent_Task> get copyWith => _$UiEvent_TaskCopyWithImpl<UiEvent_Task>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Task&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'UiEvent.task(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $UiEvent_TaskCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_TaskCopyWith(UiEvent_Task value, $Res Function(UiEvent_Task) _then) = _$UiEvent_TaskCopyWithImpl;
@useResult
$Res call({
 UiTask field0
});




}
/// @nodoc
class _$UiEvent_TaskCopyWithImpl<$Res>
    implements $UiEvent_TaskCopyWith<$Res> {
  _$UiEvent_TaskCopyWithImpl(this._self, this._then);

  final UiEvent_Task _self;
  final $Res Function(UiEvent_Task) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(UiEvent_Task(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as UiTask,
  ));
}


}

/// @nodoc


class UiEvent_TasksChanged extends UiEvent {
  const UiEvent_TasksChanged(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_TasksChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent.tasksChanged()';
}


}




/// @nodoc


class UiEvent_SettingsChanged extends UiEvent {
  const UiEvent_SettingsChanged(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_SettingsChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent.settingsChanged()';
}


}




// dart format on
