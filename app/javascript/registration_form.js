document.addEventListener('DOMContentLoaded', function() {
  const emailField = document.getElementById('email-field');
  const nameField = document.getElementById('name-field');
  const passwordField = document.getElementById('password-field');
  const passwordConfirmationField = document.getElementById('password-confirmation-field');
  const emailFeedback = document.getElementById('email-feedback');
  const nameFeedback = document.getElementById('name-feedback');
  const passwordFeedback = document.getElementById('password-feedback');
  const passwordConfirmationFeedback = document.getElementById('password-confirmation-feedback');
  const submitButton = document.getElementById('submit-button');

  function validateEmail() {
    const email = emailField.value;
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    const isEmailValid = emailRegex.test(email);

    if (email.length === 0) {
      emailFeedback.innerHTML = '';
      emailFeedback.className = 'password-feedback';
    } else if (isEmailValid) {
      emailFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      emailFeedback.className = 'password-feedback valid';
    } else {
      emailFeedback.innerHTML = `<div class="password-constraint unmet"></div>`;
      emailFeedback.className = 'password-feedback invalid';
    }

    return isEmailValid;
  }

  function validateName() {
    const name = nameField.value.trim();
    const isNameValid = name.length > 0;

    if (name.length === 0) {
      nameFeedback.innerHTML = '';
      nameFeedback.className = 'password-feedback';
    } else {
      nameFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      nameFeedback.className = 'password-feedback valid';
    }

    return isNameValid;
  }

  function validatePassword() {
    const password = passwordField.value;
    const isLengthValid = password.length >= 14;

    if (password.length === 0) {
      passwordFeedback.innerHTML = '';
      passwordFeedback.className = 'password-feedback';
    } else if (isLengthValid) {
      passwordFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      passwordFeedback.className = 'password-feedback valid';
    } else {
      const remainingChars = 14 - password.length;
      passwordFeedback.innerHTML = `<div class="password-constraint unmet"><span class="char-count">${remainingChars}</span> more character${remainingChars > 1 ? 's' : ''} needed</div>`;
      passwordFeedback.className = `password-feedback invalid`;
    }

    return isLengthValid;
  }

  function validatePasswordConfirmation() {
    const password = passwordField.value;
    const confirmation = passwordConfirmationField.value;
    const passwordsMatch = password === confirmation && confirmation.length > 0;

    if (confirmation.length === 0) {
      passwordConfirmationFeedback.innerHTML = '';
      passwordConfirmationFeedback.className = 'password-feedback';
    } else if (passwordsMatch) {
      passwordConfirmationFeedback.innerHTML = `<div class="password-constraint met">✓</div>`;
      passwordConfirmationFeedback.className = 'password-feedback valid';
    } else {
      passwordConfirmationFeedback.innerHTML = `<div class="password-constraint unmet">Passwords must match</div>`;
      passwordConfirmationFeedback.className = `password-feedback invalid`;
    }

    return passwordsMatch;
  }

  function updateSubmitButton() {
    const isEmailValid = validateEmail();
    const isNameValid = validateName();
    const isPasswordValid = validatePassword();
    const isConfirmationValid = validatePasswordConfirmation();

    const allFieldsValid = isEmailValid && isNameValid && isPasswordValid && isConfirmationValid;
    submitButton.disabled = !allFieldsValid;
  }

  // Add event listeners
  emailField.addEventListener('input', function() {
    validateEmail();
    updateSubmitButton();
  });

  nameField.addEventListener('input', function() {
    validateName();
    updateSubmitButton();
  });

  passwordField.addEventListener('input', function() {
    validatePassword();
    validatePasswordConfirmation(); // Re-validate confirmation when password changes
    updateSubmitButton();
  });

  passwordConfirmationField.addEventListener('input', function() {
    validatePasswordConfirmation();
    updateSubmitButton();
  });

  // Initial validation
  updateSubmitButton();
});
