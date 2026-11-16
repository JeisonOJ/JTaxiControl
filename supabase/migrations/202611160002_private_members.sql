-- Optional enrollment for a NEW deployment, after creating two Auth users.
-- Set these session values yourself before running this migration:
-- select set_config('jtaxi.member_one', 'YOUR_FIRST_AUTH_USER_UUID', false);
-- select set_config('jtaxi.member_two', 'YOUR_SECOND_AUTH_USER_UUID', false);
-- When unset, access stays closed. Never use sample UUIDs for real enrollment.
begin;
do $$ declare first_user uuid; second_user uuid; begin
 first_user:=nullif(current_setting('jtaxi.member_one',true),'')::uuid;
 second_user:=nullif(current_setting('jtaxi.member_two',true),'')::uuid;
 if first_user is null and second_user is null then return; end if;
 if first_user is null or second_user is null or first_user=second_user then raise exception 'Two distinct Auth user UUIDs are required'; end if;
 insert into private.app_users(user_id,slot) values(first_user,1),(second_user,2);
end $$;
commit;

