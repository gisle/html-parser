/* $Id: util.c,v 2.2 1999/12/03 12:20:42 gisle Exp $
 *
 * Copyright 1999, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

#ifndef EXTERN
#define EXTERN extern
#endif


EXTERN SV*
sv_lower(SV* sv)
{
   STRLEN len;
   char *s = SvPV_force(sv, len);
   for (; len--; s++)
	*s = toLOWER(*s);
   return sv;
}


EXTERN SV*
decode_entities(SV* sv, HV* entity2char)
{
  STRLEN len;
  char *s = SvPV_force(sv, len);
  char *t = s;
  char *end = s + len;
  char *ent_start;

  char *repl;
  STRLEN repl_len;
  char buf[1];
  

  while (s < end) {
    assert(t <= s);

    if ((*t++ = *s++) != '&')
      continue;

    ent_start = s;
    repl = 0;

    if (*s == '#') {
      int num = 0;
      /* currently this code is limited to numeric references with values
       * below 256.  Doing more need Unicode support.
       */

      s++;
      if (*s == 'x' || *s == 'X') {
	char *tmp;
	s++;
	while (*s) {
	  char *tmp = strchr(PL_hexdigit, *s);
	  if (!tmp)
	    break;
	  s++;
	  if (num < 256) {
	    num = num << 4 | ((tmp - PL_hexdigit) & 15);
	  }
	}
      }
      else {
	while (isDIGIT(*s)) {
	  if (num < 256)
	    num = num*10 + (*s - '0');
	  s++;
	}
      }
      if (num && num < 256) {
	buf[0] = num;
	repl = buf;
	repl_len = 1;
      }
    }
    else {
      char *ent_name = s;
      while (isALNUM(*s))
	s++;
      if (ent_name != s && entity2char) {
	SV** svp = hv_fetch(entity2char, ent_name, s - ent_name, 0);
	if (svp)
	  repl = SvPV(*svp, repl_len);
      }
    }

    if (repl) {
      if (*s == ';')
	s++;
      t--;  /* '&' already copied, undo it */
      if (t + repl_len > s)
	croak("Growing string not supported yet");
      while (repl_len--)
	*t++ = *repl++;
    }
    else {
      while (ent_start < s)
	*t++ = *ent_start++;
    }
  }

  if (t != s) {
    *t = '\0';
    SvCUR_set(sv, t - SvPVX(sv));
  }
  return sv;
}
