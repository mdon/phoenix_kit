lets add a new referral code system to phoenix_kit.

I already created 2 table.
And I created the folder to put the files into
lib/phoenix_kit/referral_codes
lib/phoenix_kit_web/referral_codes

phoenix_kit_referral_codes
id | code | description | status | number_of_uses | max_uses | created_by | date_created | expiration_date

phoenix_kit_referral_code_usage
id | code_id | used_by | date_used

(_by fields are user_ids)

Also added a new column to phoenix_kit_settings "modules" where to add settings for this task with the module name "referral_codes".

And now we need to add all the logic behind this. This module should appear as a togglable feature inside the modules page. When this feature is toggled it would add a setting to phoenix_kit_settings with the key "referral_codes_toggled" with the value of 1 (true). And also add a second setting with "referral_codes_required" with the value of 0 (false) - default. The module on the modules page should have now a togglable checkbox to make the them required on login. Also make a default value of how many a code has on creation. And a maximum amount of code uses allowed per code system wide.
Also on the activation of the module, it would appear like a sub module because it will have its own settings so it would need its own page.
it would look like this -
Modules
   Referral System

Now with the feature turned on, when its not required on login then they can just login without using any codes, when its required then they can't login without using any codes. 

Now to the generation of the codes, for now lets make it generate a random code of 5 symbols, or the choice of putting your own codes there.

And when a user uses a code, it would update the usage table to keep track of when who used what code.