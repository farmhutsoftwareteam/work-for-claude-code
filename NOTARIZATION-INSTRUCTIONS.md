# What I Need: Developer ID Certificate for Notarization

Hi! I need to notarize and distribute a macOS app called **Work** outside the App Store. Only the Account Holder (Admin) can create the required certificate. Here's what I need you to do:

---

## Step 1: Create a "Developer ID Application" Certificate

1. Sign in at https://developer.apple.com/account
2. Go to **Certificates, Identifiers & Profiles**
3. Click the **+** button to create a new certificate
4. Select **Developer ID Application** and click Continue
5. You'll be asked to upload a **Certificate Signing Request (CSR)** — I will provide this (see below)
6. Download the generated `.cer` file and send it to me

### How I'll create the CSR

I'll generate the CSR on my Mac using Keychain Access and send it to you. You just need to upload it in step 5 above.

---

## Step 2: Create an App-Specific Password (I can do this myself)

I'll handle this part — it uses my own Apple ID.

---

## Step 3: Confirm the Team ID

Please confirm which Apple Developer team/account this should be under and share the **Team ID** with me. You can find it at:

https://developer.apple.com/account → Membership Details → Team ID

---

## That's it!

Once I have:
- [ ] The `.cer` file (Developer ID Application certificate)
- [ ] The Team ID confirmed

I can handle everything else (building, signing, notarizing, and distributing the app).
